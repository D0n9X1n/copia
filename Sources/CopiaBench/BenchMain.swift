import AppKit
import Darwin
import CopiaApp
import CopiaCore
import CopiaFixtures
import CopiaStore
import CopiaUI

/// `copia-bench [--json FILE] [--idle SECONDS] [--opens N] [--width POINTS, default 1512] [--no-sck] [--motion-rounds N]`
/// Seeds 1,000 clips (300 images) into a temporary store, then measures the budgets in the performance spec.
/// With Screen Recording (and without `--no-sck`) it records the bench's own windows; otherwise it runs the proxy.
@MainActor
enum Bench {
	struct Budgets {
		static let idleCPUPercent = 0.20
		static let idleFootprintMB = 40.0
		static let openFootprintMB = 120.0
		static let openP95ms = 100.0

		static func acceptsIdleCPU(_ percent: Double) -> Bool { percent < idleCPUPercent }
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

	/// One to four sentences by index, so neighbouring text cards differ in length and a card that slides one slot
	/// never matches its neighbour's slot (the delete and undo settle measures rely on this).
	nonisolated static func seedText(_ i: Int) -> String {
		"Benchmark history item \(i) —" + String(repeating: " The quick brown fox jumps over the lazy dog.", count: i % 4 + 1)
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
				item = PasteboardItemData([(PasteboardTypes.string, Data(seedText(i).utf8))])
			}
			let draft = ClipDraft(items: [item], sourceBundleID: "com.apple.Notes", sourceName: "Notes",
				copiedAt: base.addingTimeInterval(TimeInterval(i)))
			let (clip, _) = try await store.insert(draft)
			if clip.kind == .image, let thumb = pngs.first {
				guard try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: thumb) else {
					throw StoreError.sqlite("benchmark image preview was rejected")
				}
			}
		}
	}

	/// The row's scroll view inside the hosting view.
	static func scrollView(in view: NSView) -> NSScrollView? {
		if let scroll = view as? NSScrollView { return scroll }
		for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
		return nil
	}

	/// True when a layer with committed contents lies in the row's leading card slot.
	static func firstCardCommitted(_ panel: StripPanel) -> Bool {
		guard let scroll = scrollView(in: panel.host), let document = scroll.documentView?.layer else { return false }
		let leading = scroll.contentView.bounds.minX
		let slot = leading..<(leading + Theme.rowPadding + Theme.cardSize.width)
		func committed(_ layer: CALayer) -> Bool {
			if layer.contents != nil {
				let rect = document.convert(layer.bounds, from: layer)
				if rect.maxX > slot.lowerBound, rect.minX < slot.upperBound { return true }
			}
			return (layer.sublayers ?? []).contains(where: committed)
		}
		return committed(document)
	}

	/// In-process proxy: toggle to the panel on screen with its first card's layer contents committed,
	/// then the end of the transaction that carries them.
	static func proxyOpen(_ controller: AppController) async -> Double {
		let start = ContinuousClock.now
		controller.toggleHistory()
		while !(controller.panel.isVisible && controller.panel.occlusionState.contains(.visible) && controller.model.cardsMounted
			&& firstCardCommitted(controller.panel)) {
			try? await Task.sleep(for: .milliseconds(1))
			if ContinuousClock.now - start > .seconds(2) { break }
		}
		await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
			CATransaction.begin()
			CATransaction.setCompletionBlock { c.resume() }
			controller.panel.contentView?.needsDisplay = true
			CATransaction.commit()
		}
		let elapsed = ContinuousClock.now - start
		return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
	}

	/// Forces a redraw while hidden: a model change the strip's body reads, then a layout and a root-layer display.
	static func hiddenControl(_ controller: AppController) async -> HiddenRender.Counters {
		Diagnostics.reset()
		controller.model.paused.toggle()
		try? await Task.sleep(for: .milliseconds(100))
		controller.panel.host.layoutSubtreeIfNeeded()
		if let layer = controller.panel.contentView?.layer {
			layer.setNeedsDisplay()
			layer.displayIfNeeded()
		}
		let counters = counters()
		controller.model.paused.toggle()
		try? await Task.sleep(for: .milliseconds(100))
		return counters
	}

	static func counters() -> HiddenRender.Counters {
		HiddenRender.Counters(bodies: Diagnostics.bodyEvaluations, layerDisplays: Diagnostics.layerDisplays,
			displayLinkTicks: Diagnostics.displayLinkTicks)
	}

	static func median(_ values: [Double]) -> Double { percentile(values, 0.5) }

	static func ms(_ seconds: Double) -> Double { (seconds * 10_000).rounded() / 10 }

	static func percentile(_ values: [Double], _ p: Double) -> Double {
		let sorted = values.sorted()
		guard !sorted.isEmpty else { return .nan }
		return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
	}

	struct Options {
		var json: URL?
		var idleSeconds = 60.0
		var opens = 50
		var width: Double?
		var noSCK = false
		var motionRounds = 3
	}

	static func run(_ options: Options) async -> Int32 {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-bench-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let suite = "copia-bench-\(UUID())"
		let defaults = UserDefaults(suiteName: suite)!, board = NSPasteboard.withUniqueName()
		defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite) }
		do {
			let controller = try AppController.scratch(directory: dir.appendingPathComponent("store"), defaults: defaults, pasteboard: board)
			try await seed(controller.store, assets: dir.appendingPathComponent("assets"))
			await controller.start(showOnboarding: false, menuAndHotkeys: false)
			if let screen = NSScreen.screens.first {
				let v = screen.visibleFrame
				let width = BenchPlan.stripWidth(requested: options.width, screen: v.width)
				controller.visibleFrameOverride = CGRect(x: v.minX, y: v.minY, width: width, height: v.height)
			}
			await controller.reload()

			// Warm the panel once, then measure the hidden, idle state.
			_ = await proxyOpen(controller)
			controller.toggleHistory()
			try? await Task.sleep(for: .seconds(3))
			let idleFootprint = footprintMB()
			Diagnostics.reset()
			let cpu0 = cpuSeconds(), wall0 = Date(), polls0 = controller.capturePollCount
			try? await Task.sleep(for: .seconds(options.idleSeconds))
			let idleCPU = (cpuSeconds() - cpu0) / Date().timeIntervalSince(wall0) * 100
			let idlePolls = controller.capturePollCount - polls0
			let idle = counters()
			let windowsOnScreen = NSApp.windows.filter(\.isVisible).count
			let hiddenOK = !controller.panel.isVisible && !controller.model.cardsMounted && controller.thumbnails.entryCount == 0
			let control = await hiddenControl(controller)
			let hidden = HiddenRender.evaluate(idle: idle, windowsOnScreen: windowsOnScreen, control: control)

			// Memory with the strip open: realise every card and thumbnail once.
			_ = await proxyOpen(controller)
			let firstOpenFootprint = footprintMB()
			if let hold = ProcessInfo.processInfo.environment["COPIA_BENCH_HOLD"].flatMap(Double.init) {
				print("HOLDING pid=\(getpid())"); fflush(stdout)
				try? await Task.sleep(for: .seconds(hold))
			}
			// Step the selection through every card, pausing a frame every few cards so the row scrolls and realises each one.
			for step in 0..<controller.model.visibleClips.count {
				controller.model.move(1)
				if step % 4 == 3 { try? await Task.sleep(for: .milliseconds(17)) }
			}
			try? await Task.sleep(for: .milliseconds(500))
			var openFootprint = footprintMB()
			controller.toggleHistory()
			try? await Task.sleep(for: .milliseconds(350))

			let screenRecording = CGPreflightScreenCaptureAccess()
			let path = BenchPlan.path(screenRecording: screenRecording, noSCK: options.noSCK)
			var checks: [(String, Bool)] = []
			// Checks on presented frames; they gate only on a 120 Hz main display (Amendment 11).
			var presented: [(String, Bool)] = []
			var report: [String: Any] = [:]
			var latencies: [Double] = []
			let openMethod = "proxy: toggle to the panel on screen with its first card's layer contents committed"
			if path == .screenCaptureKit {
				do {
					let run = try await RecordedRun.start(controller)
					let pointer = await run.pointerSelections()
					let presentedOpens = await run.latencies(options.opens)
					let motion = await run.motion(rounds: options.motionRounds)
					let scroll = await run.scroll(velocity: 4_000, seconds: 5)
					let frozen = await run.scroll(velocity: 0, seconds: 1.5)
					await run.finish()
					let refreshHz = (1 / run.refresh).rounded()
					presented.append(("pointerSelection.presentedTargetRing", RecordedRun.pointerSnapPasses(pointer)))
					report["pointerSelection"] = [
						"method": "owned windows: mouse-down dispatch, layout/transaction flush, first presented target ring at half settled contrast",
						"dispatchMs": pointer.map { $0.dispatch.map(ms) as Any? ?? NSNull() },
						"transactionFlushMs": pointer.map { $0.commit.map(ms) as Any? ?? NSNull() },
						"invalidReasons": pointer.map { $0.failure?.rawValue as Any? ?? NSNull() },
						"presentedTargetRingMs": pointer.map { $0.presented.map(ms) as Any? ?? NSNull() },
					] as [String: Any]
					report["refreshHz"] = refreshHz
					report["presentedFramesGate"] = BenchPlan.gatesPresentedFrames(refreshHz: refreshHz)
					report["presentedOpen"] = [
						"method": "screenCaptureKit: toggle to the first presented frame showing the first card",
						"p50ms": (percentile(presentedOpens, 0.5) * 10).rounded() / 10,
						"p95ms": (percentile(presentedOpens, 0.95) * 10).rounded() / 10,
						"samplesMs": presentedOpens.map { ($0 * 10).rounded() / 10 },
					] as [String: Any]
					presented.append(("presentedOpenP95ms < \(Budgets.openP95ms)", percentile(presentedOpens, 0.95) < Budgets.openP95ms))
					report["scroll"] = [
						"velocityPointsPerSecond": 4_000, "seconds": 5,
						"drive": scroll.evidence, "frozenControlDrive": frozen.evidence,
						"freshFraction": scroll.result.map { ($0.freshFraction * 1_000).rounded() / 1_000 } ?? NSNull(),
						"onTimeFraction": scroll.result.map { ($0.onTimeFraction * 1_000).rounded() / 1_000 } ?? NSNull(),
						"presentedFrames": scroll.result?.presented as Any? ?? NSNull(),
						"frozenControlFreshFraction": frozen.result.map { ($0.freshFraction * 1_000).rounded() / 1_000 } ?? NSNull(),
						"frozenControlOnTimeFraction": frozen.result.map { ($0.onTimeFraction * 1_000).rounded() / 1_000 } ?? NSNull(),
					] as [String: Any]
					presented.append(("scrollSmoothness", scroll.result?.passes ?? false))
					// The negative control must fail the same check, or the check proves nothing. It gates at any refresh.
					checks.append(("scrollFrozenControlFails", frozen.result.map { !$0.passes } ?? false))
					var motionReport: [String: Any] = [:]
					for event in SettleBudget.events {
						for reduced in [false, true] {
							let key = "\(event)" + (reduced ? ".reduced" : "")
							let samples = motion[key] ?? []
							let settled = samples.compactMap { $0?.seconds }
							let limit = SettleBudget.limit(event, reduced: reduced)
							let passes = !samples.isEmpty && samples.count == options.motionRounds && settled.count == samples.count && median(settled) <= limit
							presented.append(("motionSettle.\(key)", passes))
							motionReport[key] = [
								"analyticMs": ms(SettleBudget.analytic(event, reduced: reduced)), "limitMs": ms(limit),
								"medianMs": settled.isEmpty ? NSNull() : ms(median(settled)) as Any,
								"samplesMs": samples.map { $0.map { ms($0.seconds) } ?? -1 },
								"interruptedRounds": run.motionInterruptions[key] ?? [],
								"fromTriggerMs": samples.map { $0.map { ms($0.fromTrigger) } ?? -1 },
							] as [String: Any]
						}
					}
					report["motionSettle"] = motionReport
					let routed = BenchPlan.route(presented: presented, refreshHz: refreshHz)
					checks += routed.gated
					if !routed.reported.isEmpty {
						report["reportedOnly"] = [
							"reason": "main display at \(Int(refreshHz)) Hz; presented-frame checks gate at 120 Hz (Amendment 11)",
							"checks": routed.reported.map { ["check": $0.0, "passes": $0.1] as [String: Any] },
						] as [String: Any]
					}
				} catch {
					checks.append(("screenCaptureKitStarted", false))
					report["screenCaptureKitError"] = "\(error)"
				}
			}
			// The in-process open gates on every path and display.
			for _ in 0..<options.opens {
				latencies.append(await proxyOpen(controller))
				controller.toggleHistory()
				try? await Task.sleep(for: .milliseconds(350))
			}
			openFootprint = max(openFootprint, footprintMB())
			let p95 = percentile(latencies, 0.95)

			checks = [
				("idleCPUPercent < \(Budgets.idleCPUPercent)", Budgets.acceptsIdleCPU(idleCPU)),
				("idleFootprintMB < \(Budgets.idleFootprintMB)", idleFootprint < Budgets.idleFootprintMB),
				("openFootprintMB < \(Budgets.openFootprintMB)", openFootprint < Budgets.openFootprintMB),
				("openP95ms < \(Budgets.openP95ms)", p95 < Budgets.openP95ms),
				("hiddenReleasesCards", hiddenOK),
				("privateBoardPollingActive", options.idleSeconds < 1 || idlePolls > 0),
			] + hidden.failures.map { ($0, false) } + checks
			let skips = BenchPlan.skips(path: path, screenRecording: screenRecording)
			report.merge([
				"path": path.rawValue,
				"screenRecording": screenRecording,
				"openMethod": openMethod,
				"skipped": skips.map { ["check": $0.check, "reason": $0.reason] },
				"clips": controller.model.clips.count,
				"idleSeconds": options.idleSeconds,
				"privateBoardPolls": idlePolls,
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
				"hidden": [
					"bodies": idle.bodies, "layerDisplays": idle.layerDisplays, "displayLinkTicks": idle.displayLinkTicks,
					"windowsOnScreen": windowsOnScreen,
					"controlBodies": control.bodies, "controlLayerDisplays": control.layerDisplays,
					"displayLinks": "Copia owns no display link, so displayLinkTicks stays 0 by construction",
				] as [String: Any],
				"failed": checks.filter { !$0.1 }.map(\.0),
				"arch": {
					#if arch(arm64)
					"arm64"
					#else
					"x86_64"
					#endif
				}(),
			]) { _, new in new }
			let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
			if let json = options.json { try data.write(to: json) }
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
		var options = Bench.Options()
		options.json = value("--json").map { URL(fileURLWithPath: $0) }
		options.idleSeconds = value("--idle").flatMap(Double.init) ?? 60
		options.opens = value("--opens").flatMap(Int.init) ?? 50
		options.width = value("--width").flatMap(Double.init)
		options.noSCK = args.contains("--no-sck")
		options.motionRounds = value("--motion-rounds").flatMap(Int.init) ?? 3
		Task {
			exit(await Bench.run(options))
		}
		app.run()
	}
}
