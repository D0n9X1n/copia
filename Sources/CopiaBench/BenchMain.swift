import AppKit
import Darwin
import CopiaApp
import CopiaCore
import CopiaFixtures
import CopiaStore

/// `copia-bench [--json FILE] [--idle SECONDS] [--opens N] [--refresh-hz 60|120]`
/// Seeds 1,000 clips (300 images) into a temporary store, then measures the budgets in the performance spec.
@MainActor
enum Bench {
	struct Budgets {
		static let idleCPUPercent = 0.1
		static let idleFootprintMB = 40.0
		static let openFootprintMB = 120.0
		static let openP95ms = 100.0
	}

	static func cpuSeconds() -> Double {
		var usage = rusage()
		getrusage(RUSAGE_SELF, &usage)
		func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
		return seconds(usage.ru_utime) + seconds(usage.ru_stime)
	}

	static func footprintMB() -> Double {
		var info = rusage_info_v4()
		let result = withUnsafeMutablePointer(to: &info) {
			$0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
		}
		return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
	}

	static func seed(_ store: ClipStore, assets: URL) async throws {
		let images = try FixtureAssets.prepare(in: assets)
		var pngs: [Data] = []
		for clip in images.mixed + images.extremes {
			if case let .ready(url) = clip.preview, let data = try? Data(contentsOf: url) { pngs.append(data) }
		}
		let base = Date().addingTimeInterval(-3_600)
		for i in 0..<1_000 {
			let item: PasteboardItemData
			if i % 10 < 3, !pngs.isEmpty {
				// Vary one trailing byte so each image is a distinct clip.
				var data = pngs[i % pngs.count]
				data.append(contentsOf: withUnsafeBytes(of: UInt32(i).bigEndian, Array.init))
				item = PasteboardItemData([(PasteboardTypes.png, data)])
			} else {
				item = PasteboardItemData([(PasteboardTypes.string, Data("Benchmark history item \(i) — the quick brown fox jumps over the lazy dog.".utf8))])
			}
			let draft = ClipDraft(items: [item], sourceBundleID: "com.apple.Notes", sourceName: "Notes",
				copiedAt: base.addingTimeInterval(TimeInterval(i)))
			let (clip, _) = try await store.insert(draft)
			if clip.kind == .image, let thumb = pngs.first {
				_ = try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: thumb)
			}
		}
	}

	/// Time from toggle to the first display frame where the panel is on screen with its cards mounted.
	static func openLatency(_ controller: AppController) async -> Double {
		let start = ContinuousClock.now
		controller.toggleHistory()
		while !(controller.panel.isVisible && controller.panel.occlusionState.contains(.visible) && controller.model.cardsMounted) {
			try? await Task.sleep(for: .milliseconds(1))
			if ContinuousClock.now - start > .seconds(2) { break }
		}
		// One more frame so the first layout has committed.
		await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
			CATransaction.begin()
			CATransaction.setCompletionBlock { c.resume() }
			controller.panel.contentView?.needsDisplay = true
			CATransaction.commit()
		}
		let elapsed = ContinuousClock.now - start
		return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
	}

	static func percentile(_ values: [Double], _ p: Double) -> Double {
		let sorted = values.sorted()
		guard !sorted.isEmpty else { return .nan }
		return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
	}

	static func run(json: URL?, idleSeconds: Double, opens: Int, width: Double?) async -> Int32 {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-bench-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let defaults = UserDefaults(suiteName: "copia-bench-\(UUID().uuidString)")!
		defaults.set(true, forKey: "onboarded")
		// Paused capture still polls the real pasteboard every 0.5 s, so idle CPU includes polling,
		// but nothing the user copies during the run is read or stored.
		defaults.set(true, forKey: "paused")
		do {
			let controller = try AppController(directory: dir.appendingPathComponent("store"), defaults: defaults)
			try await seed(controller.store, assets: dir.appendingPathComponent("assets"))
			await controller.start(showOnboarding: false, menuAndHotkeys: false)
			if let width, let screen = NSScreen.screens.first {
				let v = screen.visibleFrame
				controller.visibleFrameOverride = CGRect(x: v.minX, y: v.minY, width: min(width, v.width), height: v.height)
			}
			await controller.reload()

			// Warm the panel once, then measure the hidden, idle state.
			_ = await openLatency(controller)
			controller.toggleHistory()
			try? await Task.sleep(for: .seconds(3))
			let idleFootprint = footprintMB()
			let cpu0 = cpuSeconds(), wall0 = Date()
			try? await Task.sleep(for: .seconds(idleSeconds))
			let idleCPU = (cpuSeconds() - cpu0) / Date().timeIntervalSince(wall0) * 100
			let hiddenOK = !controller.panel.isVisible && !controller.model.cardsMounted && controller.thumbnails.entryCount == 0

			var latencies: [Double] = []
			var openFootprint = 0.0
			var firstOpenFootprint = 0.0
			for i in 0..<opens {
				latencies.append(await openLatency(controller))
				if i == 0 {
					firstOpenFootprint = footprintMB()
					if let hold = ProcessInfo.processInfo.environment["COPIA_BENCH_HOLD"].flatMap(Double.init) {
						print("HOLDING pid=\(getpid())"); fflush(stdout)
						try? await Task.sleep(for: .seconds(hold))
					}
				}
				if i == 0 {
					// Scroll through the whole row so every card and thumbnail is realised once.
					for _ in 0..<controller.model.visibleClips.count { controller.model.move(1) }
					try? await Task.sleep(for: .milliseconds(500))
					openFootprint = max(openFootprint, footprintMB())
				}
				controller.toggleHistory()
				try? await Task.sleep(for: .milliseconds(350))
			}
			openFootprint = max(openFootprint, footprintMB())
			let p95 = percentile(latencies, 0.95)

			let checks: [(String, Bool)] = [
				("idleCPUPercent < \(Budgets.idleCPUPercent)", idleCPU < Budgets.idleCPUPercent),
				("idleFootprintMB < \(Budgets.idleFootprintMB)", idleFootprint < Budgets.idleFootprintMB),
				("openFootprintMB < \(Budgets.openFootprintMB)", openFootprint < Budgets.openFootprintMB),
				("openP95ms < \(Budgets.openP95ms)", p95 < Budgets.openP95ms),
				("hiddenReleasesCards", hiddenOK),
			]
			let report: [String: Any] = [
				"clips": controller.model.clips.count,
				"idleSeconds": idleSeconds,
				"idleCPUPercent": (idleCPU * 1_000).rounded() / 1_000,
				"idleFootprintMB": (idleFootprint * 10).rounded() / 10,
				"openFootprintMB": (openFootprint * 10).rounded() / 10,
				"openFootprintBeforeScrollMB": (firstOpenFootprint * 10).rounded() / 10,
				"openP50ms": (percentile(latencies, 0.5) * 10).rounded() / 10,
				"openP95ms": (p95 * 10).rounded() / 10,
				"opens": latencies.count,
				"openSamplesMs": latencies.map { ($0 * 10).rounded() / 10 },
				"stripWidthPoints": controller.panel.frame.width,
				"backingScale": controller.panel.backingScaleFactor,
				"hiddenReleasesCards": hiddenOK,
				"failed": checks.filter { !$0.1 }.map(\.0),
				"arch": {
					#if arch(arm64)
					"arm64"
					#else
					"x86_64"
					#endif
				}(),
			]
			let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
			if let json { try data.write(to: json) }
			print(String(decoding: data, as: UTF8.self))
			return checks.allSatisfy(\.1) ? 0 : 1
		} catch {
			FileHandle.standardError.write(Data("copia-bench failed: \(error)\n".utf8))
			return 2
		}
	}
}

@main
enum Main {
	@MainActor static func main() {
		let args = CommandLine.arguments
		func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)
		Task {
			let code = await Bench.run(json: value("--json").map { URL(fileURLWithPath: $0) },
				idleSeconds: Double(value("--idle") ?? "60") ?? 60, opens: Int(value("--opens") ?? "50") ?? 50,
				width: value("--width").flatMap(Double.init))
			exit(code)
		}
		app.run()
	}
}
