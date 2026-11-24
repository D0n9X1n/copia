import AppKit
import SwiftUI
import ScreenCaptureKit
import ImageIO
import CopiaCore
import CopiaUI
import CopiaFixtures

/// One state to capture.
struct Scene {
	let name: String
	var dark = false
	var wallpaperDark = false
	var overrides = CopiaOverrides()
	var clips: (_ mixed: [Clip], _ extremes: [Clip]) -> [Clip] = { mixed, _ in mixed }
	var prepare: @MainActor (StripModel) async -> Void = { _ in }
	/// Records contrast probes (glass text and the lens) in the manifest for `--check-contrast`.
	var checkContrast = false
	/// Runs after the strip settles under a slowed animator; the capture lands halfway through it.
	var midway: (@MainActor (StripModel) async -> Void)?
	/// Lays every card out at once (CardSheet) instead of the strip.
	var sheet = false
	/// Opens as if the clipboard held something Copia didn't save, so ⎋ can't restore it.
	var unknownClipboard = false
}

/// Renders each strip state as a real window over a fixed wallpaper and captures it with `screencapture`.
@MainActor
enum RenderRunner {
	/// A 1440×900 "screen" placed at the top-left of the main display.
	static let stage = CGSize(width: 1440, height: 900)
	/// Midway scenes run their transition this long and are captured at half of it.
	static let midwayDuration = 5.0

	static func scenes() -> [Scene] {
		var list: [Scene] = []
		for dark in [false, true] {
			for wallpaperDark in [false, true] {
				let suffix = "\(dark ? "dark" : "light")-\(wallpaperDark ? "darkwall" : "brightwall")"
				list.append(Scene(name: "01-mixed-\(suffix)", dark: dark, wallpaperDark: wallpaperDark, checkContrast: true))
			}
			let mode = dark ? "dark" : "light"
			list.append(Scene(name: "02-selection-mid-\(mode)", dark: dark, prepare: { m in m.select(m.clips[5].id) }))
			list.append(Scene(name: "02-command-badges-\(mode)", dark: dark, prepare: { m in m.commandHeld = true }))
			list.append(Scene(name: "03-search-\(mode)", dark: dark, prepare: { m in m.query = "the" }))
			list.append(Scene(name: "03-no-results-\(mode)", dark: dark, prepare: { m in m.query = "zebra" }, checkContrast: true))
			for wallpaperDark in [false, true] {
				let wall = wallpaperDark ? "-darkwall" : ""
				list.append(Scene(name: "04-empty-\(mode)\(wall)", dark: dark, wallpaperDark: wallpaperDark, clips: { _, _ in [] },
					checkContrast: true))
				list.append(Scene(name: "04-paused-\(mode)\(wall)", dark: dark, wallpaperDark: wallpaperDark,
					prepare: { m in m.paused = true }, checkContrast: true))
			}
			list.append(Scene(name: "05-extremes-\(mode)", dark: dark, clips: { _, e in e + [Fixtures.failed, Fixtures.pending] }))
			list.append(Scene(name: "05-sheet-\(mode)", dark: dark, clips: { _, e in e + [Fixtures.failed, Fixtures.pending] }, sheet: true))
			list.append(Scene(name: "06-delete-toast-\(mode)", dark: dark, prepare: { m in m.select(m.clips[1].id); await m.deleteSelected() }))
			list.append(Scene(name: "06-storage-cleanup-\(mode)", dark: dark, prepare: { $0.storageStatus = .cleanupPending }))
			list.append(Scene(name: "06-storage-recovery-\(mode)", dark: dark, prepare: { $0.storageStatus = .recoveryRequired }))
			list.append(Scene(name: "07-reduce-transparency-\(mode)", dark: dark, overrides: CopiaOverrides(reduceTransparency: true)))
			list.append(Scene(name: "07-increase-contrast-\(mode)", dark: dark, overrides: CopiaOverrides(highContrast: true)))
			list.append(Scene(name: "08-hover-\(mode)", dark: dark, prepare: { m in m.hoveredID = m.clips[2].id }))
			// Browsing: the clipboard followed the lens to the third card, and the chip beside Search offers ⎋.
			list.append(Scene(name: "08-browsing-\(mode)", dark: dark, prepare: { m in
				m.browse(2); try? await Task.sleep(for: .milliseconds(400))
			}))
			list.append(Scene(name: "08-browsing-unsaved-\(mode)", dark: dark, prepare: { m in
				m.browse(2); try? await Task.sleep(for: .milliseconds(400))
			}, unknownClipboard: true))
			// Browsing a search: the chip only confirms the copy, as ⎋ clears the query first.
			list.append(Scene(name: "08-browsing-search-\(mode)", dark: dark, prepare: { m in
				m.query = "e"; try? await Task.sleep(for: .milliseconds(100))
				m.browse(1); try? await Task.sleep(for: .milliseconds(400))
			}))
			// A click put a different card on the clipboard: the chip confirms it for 2 s, with no ⎋ offer.
			// Its 2 s timer never fires here, so slow thumbnails can't outlast the chip before the capture.
			list.append(Scene(name: "08-click-copied-\(mode)", dark: dark, prepare: { m in
				m.clock = ToastClock { _, _ in {} }
				m.selectOnPress(m.clips[2].id); await m.copy(id: m.clips[2].id, plain: false, dismiss: false)
			}))
			// The footer pin: filled on a pinned card, an outline on the primary and hovered cards, an empty slot elsewhere.
			list.append(Scene(name: "08-pins-\(mode)", dark: dark, clips: { mixed, _ in
				var c = mixed; c[0].isPinned = true; return c
			}, prepare: { m in m.hoveredID = m.clips[2].id }))
			list.append(Scene(name: "08-loading-\(mode)", dark: dark, clips: { mixed, _ in
				var c = mixed; c[2].preview = .pending; c[3].preview = .pending; return c
			}))
			// Halfway through open: sliding up from below the window, or (Reduce Motion) fading in place.
			list.append(Scene(name: "09-open-midway-\(mode)", dark: dark, midway: replayOpen))
			list.append(Scene(name: "09-reduce-motion-open-\(mode)", dark: dark, overrides: CopiaOverrides(reduceMotion: true),
				midway: replayOpen))
			// Halfway through a delete with Reduce Motion: the card crossfades without shrinking.
			list.append(Scene(name: "09-reduce-motion-delete-\(mode)", dark: dark, overrides: CopiaOverrides(reduceMotion: true),
				prepare: { m in m.select(m.clips[1].id) }, midway: { m in await m.deleteSelected() }))
		}
		return list
	}

	/// Puts the strip back in its hidden state, lets it draw there, then opens it again.
	static func replayOpen(_ model: StripModel) async {
		model.open(clipboard: model.clips.first.map { ClipboardCard(id: $0.id) })
		try? await Task.sleep(for: .milliseconds(300))
		model.animateIn()
	}

	/// Every transition as one long linear ramp, so a capture can land halfway through it.
	static func slowed(_ seconds: Double) -> Animator {
		Animator { _, change, completion in
			withAnimation(.linear(duration: seconds), completionCriteria: .logicallyComplete, change, completion: completion)
		}
	}

	static func run(output: URL, only: String?) async throws {
		try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
		let assets = try FixtureAssets.prepare(in: output.appendingPathComponent("assets"), filePreviews: true)
		guard let screen = NSScreen.screens.first else { throw RenderError.noScreen }
		let visible = CGRect(x: screen.frame.minX, y: screen.frame.maxY - stage.height, width: stage.width, height: stage.height)
		// Contrast probes are read from the strip's accessibility tree.
		AccessibilityNode.enableInProcess()

		let wallpaper = NSWindow(contentRect: visible, styleMask: .borderless, backing: .buffered, defer: false)
		wallpaper.level = .floating
		wallpaper.isReleasedWhenClosed = false
		let panel = StripPanel()
		defer { panel.orderOut(nil); wallpaper.orderOut(nil) }

		var manifest: [[String: Any]] = []
		for scene in scenes() where only.map({ scene.name.contains($0) }) ?? true {
			NSApp.appearance = NSAppearance(named: scene.dark ? .darkAqua : .aqua)
			wallpaper.contentView = NSHostingView(rootView: Wallpaper(dark: scene.wallpaperDark))
			wallpaper.orderFrontRegardless()
			let url = output.appendingPathComponent("\(scene.name).png")
			let clips = scene.clips(assets.mixed, assets.extremes)
			if scene.sheet {
				panel.orderOut(nil)
				let region = try await captureSheet(scene, clips: clips, stage: visible, screen: screen, wallpaper: wallpaper, to: url)
				manifest.append(["scene": scene.name, "file": url.lastPathComponent, "dark": scene.dark,
					"wallpaperDark": scene.wallpaperDark, "frame": NSStringFromRect(region)])
				print("rendered \(scene.name)")
				continue
			}
			let model = try await showStrip(scene, clips: clips, in: visible, panel: panel)
			if let midway = scene.midway {
				model.animator = slowed(midwayDuration)
				await midway(model)
				try await Task.sleep(for: .seconds(midwayDuration / 2))
			}

			let region = PanelLayout.stripFrame(in: visible).insetBy(dx: -28, dy: -28).intersection(visible)
			let probes = scene.checkContrast ? contrastProbes(in: panel, region: region) : []
			try await capture(region, on: screen, windows: [wallpaper, panel], to: url)
			var row: [String: Any] = ["scene": scene.name, "file": url.lastPathComponent, "dark": scene.dark,
				"wallpaperDark": scene.wallpaperDark, "frame": NSStringFromRect(panel.frame)]
			if scene.checkContrast {
				row["regionWidth"] = region.width
				row["probes"] = probes.map(\.json)
			}
			manifest.append(row)
			print("rendered \(scene.name)")
		}
		if only.map({ "shell".contains($0) || $0.hasPrefix("1") }) ?? true {
			manifest += try await renderShell(output: output, screen: screen, stage: visible, wallpaper: wallpaper)
		}
		if only.map({ "12-icon-review".contains($0) }) ?? true {
			manifest.append(try renderIconReview(output: output))
		}
		let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
		try data.write(to: output.appendingPathComponent("manifest.json"))
	}

	/// Every text on the glass (outside the cards) and the selected card's lens ring, in points from `region`'s top-left.
	static func contrastProbes(in panel: StripPanel, region: CGRect) -> [ContrastCheck.Probe] {
		var seen = Set<ObjectIdentifier>()
		let nodes = AccessibilityNode(panel.host).all.filter { seen.insert(ObjectIdentifier($0.object)).inserted }
		func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX - region.minX, y: region.maxY - r.maxY, width: r.width, height: r.height) }
		var probes: [ContrastCheck.Probe] = []
		for node in nodes where node.actions.isEmpty && node.frame.width > 0 {
			switch node.role {
			case NSAccessibility.Role.staticText.rawValue:
				let text = node.value.isEmpty ? node.label : node.value
				probes.append(.init(kind: .text, name: "text “\(text.prefix(32))”", rect: local(node.frame)))
			case NSAccessibility.Role.textField.rawValue where node.value.isEmpty:
				probes.append(.init(kind: .text, name: "search placeholder", rect: local(node.frame)))
			default: break
			}
		}
		// The selected card's frame includes the lens background; the ring is the card grown by the lens outset.
		if let card = nodes.first(where: { !$0.actions.isEmpty && $0.isSelected }) {
			let f = card.frame
			let size = CGSize(width: Theme.cardSize.width + 2 * Theme.lensOutset, height: Theme.cardSize.height + 2 * Theme.lensOutset)
			let ring = CGRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height)
			probes.append(.init(kind: .lens, name: "lens", rect: local(ring)))
		}
		return probes
	}

	/// Prints each probe's ratio and returns the exit status for `--check-contrast DIR`.
	static func checkContrast(_ directory: URL) -> Int32 {
		do {
			let results = try ContrastCheck.check(directory: directory)
			for r in results {
				print("\(r.passes ? "PASS" : "FAIL")  \(String(format: "%5.2f", r.ratio)):1 (min \(r.minimum))  \(r.scene)  \(r.probe)")
			}
			let failures = results.filter { !$0.passes }.count
			print(results.isEmpty ? "no contrast probes in \(directory.path)/manifest.json"
				: "\(results.count - failures) of \(results.count) probes pass")
			return ContrastCheck.exitCode(results)
		} catch {
			FileHandle.standardError.write(Data("check-contrast failed: \(error)\n".utf8))
			return 1
		}
	}

	/// Shows every card at once on a glass sheet centered on the stage, waits for its previews, and captures it.
	static func captureSheet(_ scene: Scene, clips: [Clip], stage: CGRect, screen: NSScreen, wallpaper: NSWindow, to url: URL) async throws -> CGRect {
		let thumbnails = ThumbnailCache()
		let host = NSHostingView(rootView: CardSheet(clips: clips, thumbnails: thumbnails, now: Fixtures.now)
			.environment(\.copiaOverrides, scene.overrides))
		let size = host.fittingSize
		let window = NSWindow(contentRect: CGRect(x: stage.midX - size.width / 2, y: stage.midY - size.height / 2,
			width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = true
		window.level = .floating + 1
		window.isReleasedWhenClosed = false
		window.contentView = host
		window.orderFrontRegardless()
		defer { window.orderOut(nil) }
		try await waitForPreviews(clips, in: thumbnails)
		window.invalidateShadow()
		let region = window.frame.insetBy(dx: -28, dy: -28).intersection(stage)
		try await capture(region, on: screen, windows: [wallpaper, window], to: url)
		return region
	}

	/// Waits until every saved preview (thumbnail or site icon) has decoded, then lets the fade finish.
	static func waitForPreviews(_ clips: [Clip], in thumbnails: ThumbnailCache) async throws {
		let expected = clips.compactMap { clip -> URL? in
			switch clip.preview {
			case let .ready(url), let .icon(url): url
			case .pending, .failed: nil
			}
		}
		for _ in 0..<200 where !expected.allSatisfy({ thumbnails.cached($0) != nil }) {
			try await Task.sleep(for: .milliseconds(50))
		}
		try await Task.sleep(for: .milliseconds(450))
	}

	/// Shows `scene` in the strip and waits until every visible preview has decoded,
	/// so no capture shows a loading placeholder by accident.
	@discardableResult
	static func showStrip(_ scene: Scene, clips: [Clip], in visible: CGRect, panel: StripPanel) async throws -> StripModel {
		let model = StripModel(clips: clips, animator: .immediate)
		let thumbnails = ThumbnailCache()
		let root = StripView(model: model, focus: SearchFocus(), thumbnails: thumbnails, now: { Fixtures.now })
			.environment(\.copiaOverrides, scene.overrides)
			// A fresh identity per scene: otherwise cards keep the previous scene's state and never load this cache.
			.id(UUID())
		panel.host.rootView = AnyView(root)
		panel.setFrame(PanelLayout.windowFrame(in: visible), display: true)
		panel.orderFrontRegardless()
		// The usual case: the newest card is what the clipboard holds.
		model.open(clipboard: scene.unknownClipboard ? nil : model.clips.first.map { ClipboardCard(id: $0.id) })
		model.animateIn()
		await scene.prepare(model)
		try await waitForPreviews(Array(model.visibleClips.prefix(12)), in: thumbnails)
		// As AppController does on open: the first shadow was taken while the strip sat below the window.
		panel.invalidateShadow()
		try await Task.sleep(for: .milliseconds(100))
		return model
	}

	/// Settings tabs and onboarding steps in real titled windows, light and dark.
	static func renderShell(output: URL, screen: NSScreen, stage: CGRect, wallpaper: NSWindow) async throws -> [[String: Any]] {
		var rows: [[String: Any]] = []
		let icons = try AppIcons.images(in: output.appendingPathComponent("assets"))
		// Shell windows render as key windows, as users see them.
		NSApp.setActivationPolicy(.regular)
		NSApp.activate()
		defer { NSApp.setActivationPolicy(.accessory) }
		for dark in [false, true] {
			NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
			wallpaper.contentView = NSHostingView(rootView: Wallpaper(dark: dark))
			wallpaper.orderFrontRegardless()
			let mode = dark ? "dark" : "light"
			let appIcon = dark ? icons.dark : icons.light
			let shell = ShellModel()
			shell.ignoredApps = ["com.apple.Passwords", "com.1password.1password"]
			for tab in SettingsTab.allCases {
				let window = settingsWindow(model: shell, tab: tab, level: .floating + 1)
				rows.append(try await capture(window, name: "10-settings-\(tab.rawValue.lowercased())-\(mode)", output: output, stage: stage))
			}
			for (name, status) in [("cleanup", StorageStatus.cleanupPending), ("recovery", .recoveryRequired)] {
				shell.storageStatus = status
				rows.append(try await capture(settingsWindow(model: shell, tab: .general, level: .floating + 1),
					name: "10-settings-storage-\(name)-\(mode)", output: output, stage: stage))
			}
			shell.storageStatus = .ready
			rows.append(try await captureEraseConfirmation(name: "10-settings-erase-confirm-\(mode)", output: output, stage: stage, screen: screen, wallpaper: wallpaper))
			for (index, step) in OnboardingStep.allCases.enumerated() {
				for granted in [false, true] where step == .pasteboard || granted {
					let model = ShellModel()
					model.onboardingStep = index
					model.permissions = PermissionState(pasteboard: granted ? .allow : .ask)
					let suffix = step == .pasteboard ? (granted ? "-granted" : "-needed") : ""
					rows.append(try await capture(OnboardingView(model: model, icon: appIcon),
						title: "", name: "11-onboarding-\(index + 1)-\(step.title.lowercased().replacingOccurrences(of: " ", with: "-"))\(suffix)-\(mode)", output: output, stage: stage,
						screen: screen, hiddenTitle: true))
				}
			}
		}
		return rows
	}

	/// The app icon from `Resources/AppIcon.icon` at 1024, 128, 32 and 16 px on a light and a dark row, as
	/// `scripts/render-icon.swift` lays it out. Composed from Icon Composer's exports: no window, no screen capture.
	static func renderIconReview(output: URL) throws -> [String: Any] {
		let assets = output.appendingPathComponent("assets")
		try AppIcons.export(to: assets)
		let light = try AppIcons.padded(assets.appendingPathComponent("icon-Default.png"), pixels: 1024)
		let dark = try AppIcons.padded(assets.appendingPathComponent("icon-Dark.png"), pixels: 1024)
		guard let sheet = IconReview.sheet(light: light, dark: dark) else { throw RenderError.captureFailed("12-icon-review") }
		let ctx = try AppIcons.context(width: sheet.width, height: sheet.height)
		ctx.draw(sheet, in: CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
		let url = output.appendingPathComponent("12-icon-review.png")
		try AppIcons.write(ctx, to: url)
		print("rendered 12-icon-review")
		return ["scene": "12-icon-review", "file": url.lastPathComponent]
	}

	/// A titled window around `view` that always draws as key.
	static func window<V: View>(_ view: V, title: String, hiddenTitle: Bool, level: NSWindow.Level) -> NSWindow {
		let controller = NSHostingController(rootView: view)
		let window = KeyWindow(contentViewController: controller)
		window.title = title
		window.styleMask = hiddenTitle ? [.titled, .closable, .fullSizeContentView] : [.titled, .closable]
		window.titlebarAppearsTransparent = hiddenTitle
		window.titleVisibility = hiddenTitle ? .hidden : .visible
		window.level = level
		window.isReleasedWhenClosed = false
		// Size it now: callers place the window by its frame before it is ever laid out.
		window.setContentSize(controller.view.fittingSize)
		return window
	}

	/// The app's Settings window, with its toolbar tabs, drawn as key.
	static func settingsWindow(model: ShellModel, tab: SettingsTab, level: NSWindow.Level) -> NSWindow {
		let window = SettingsView.makeSettingsWindow(model: model, initialTab: tab,
			window: KeyWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false))
		window.level = level
		return window
	}

	static func capture<V: View>(_ view: V, title: String, name: String, output: URL, stage: CGRect, screen: NSScreen,
		hiddenTitle: Bool) async throws -> [String: Any] {
		try await capture(window(view, title: title, hiddenTitle: hiddenTitle, level: .floating + 1), name: name, output: output, stage: stage)
	}

	/// Centers `window` on the stage and captures it alone.
	static func capture(_ window: NSWindow, name: String, output: URL, stage: CGRect) async throws -> [String: Any] {
		window.setFrameOrigin(NSPoint(x: stage.midX - window.frame.width / 2, y: stage.midY - window.frame.height / 2))
		window.makeKeyAndOrderFront(nil)
		NSApp.activate()
		defer { window.orderOut(nil) }
		try await Task.sleep(for: .milliseconds(700))
		let url = output.appendingPathComponent("\(name).png")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
		process.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
		try process.run()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else { throw RenderError.captureFailed(name) }
		print("rendered \(name)")
		return ["scene": name, "file": url.lastPathComponent]
	}

	/// Settings → General with the Erase History confirmation up. The dialog is its own sheet window,
	/// so this captures the screen region around the window and its sheet rather than one window.
	static func captureEraseConfirmation(name: String, output: URL, stage: CGRect, screen: NSScreen, wallpaper: NSWindow) async throws -> [String: Any] {
		let model = ShellModel()
		let window = settingsWindow(model: model, tab: .general, level: .floating + 1)
		window.setFrameOrigin(NSPoint(x: stage.midX - window.frame.width / 2, y: stage.midY - window.frame.height / 2))
		window.makeKeyAndOrderFront(nil)
		NSApp.activate()
		defer { model.cancelErase(); window.orderOut(nil) }
		try await Task.sleep(for: .milliseconds(400))
		model.requestErase()
		try await Task.sleep(for: .milliseconds(900))
		guard let sheet = window.attachedSheet else { throw RenderError.captureFailed(name) }
		let covered = window.frame.union(sheet.frame)
		let url = output.appendingPathComponent("\(name).png")
		try await capture(covered.insetBy(dx: -24, dy: -24).intersection(stage), on: screen, windows: [wallpaper, window, sheet], to: url)
		print("rendered \(name)")
		return ["scene": name, "file": url.lastPathComponent]
	}

	static func capture(_ rect: CGRect, on screen: NSScreen, windows: [NSWindow], to url: URL) async throws {
		let content = try await SCShareableContent.currentProcess
		let ids = Set(windows.map { CGWindowID($0.windowNumber) })
		let owned = content.windows.filter { ids.contains($0.windowID) }
		guard !owned.isEmpty, owned.count == windows.count,
			let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
			let display = content.displays.first(where: { $0.displayID == id }) else { throw RenderError.captureFailed(url.lastPathComponent) }
		let filter = SCContentFilter(display: display, including: owned)
		let config = SCStreamConfiguration()
		config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
		config.width = Int((rect.width * screen.backingScaleFactor).rounded())
		config.height = Int((rect.height * screen.backingScaleFactor).rounded())
		config.showsCursor = false
		let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
		guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw RenderError.captureFailed(url.lastPathComponent) }
		CGImageDestinationAddImage(dest, image, nil)
		guard CGImageDestinationFinalize(dest) else { throw RenderError.captureFailed(url.lastPathComponent) }
	}

	enum RenderError: Error { case noScreen, captureFailed(String) }
}

/// Draws as the key window even when a terminal-launched process can't take focus, as users see it.
final class KeyWindow: NSWindow {
	override var isKeyWindow: Bool { true }
	override var isMainWindow: Bool { true }
}

/// A fixed wallpaper with diagonal bands so the glass blur is visible.
struct Wallpaper: View {
	let dark: Bool
	/// Soft color fields, as on a real desktop, for the README's product shots.
	var aurora = false
	var body: some View {
		if aurora { Aurora(dark: dark) } else { bands }
	}

	private var bands: some View {
		ZStack {
			LinearGradient(colors: dark ? [Color(hex: 0x101824), Color(hex: 0x29364A)] : [Color(hex: 0xF6E7CA), Color(hex: 0xCADFF5)],
				startPoint: .topLeading, endPoint: .bottomTrailing)
			Canvas { ctx, size in
				for i in 0..<14 {
					let x = CGFloat(i) * size.width / 9 - size.width * 0.3
					var path = Path()
					path.move(to: CGPoint(x: x, y: size.height))
					path.addLine(to: CGPoint(x: x + size.width * 0.35, y: 0))
					path.addLine(to: CGPoint(x: x + size.width * 0.35 + 70, y: 0))
					path.addLine(to: CGPoint(x: x + 70, y: size.height))
					let palette: [UInt32] = dark ? [0x3A5A8C, 0x6B4E9B, 0x2E7D6B] : [0xFF9F6E, 0x7FB2F0, 0xF5C04A]
					ctx.fill(path, with: .color(Color(hex: palette[i % 3]).opacity(dark ? 0.45 : 0.5)))
				}
			}
		}
	}
}

extension Color {
	init(hex: UInt32) {
		self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
	}
}

/// Radial color fields over a soft base gradient. Positions are fractions of the canvas, so every crop keeps the mix.
struct Aurora: View {
	let dark: Bool
	private typealias Blob = (color: UInt32, x: CGFloat, y: CGFloat, radius: CGFloat)
	private var base: [UInt32] { dark ? [0x0E1222, 0x24183A] : [0xFBEFE6, 0xE9E6FA] }
	private var blobs: [Blob] {
		dark ? [(0xFF5A3C, 0.12, 0.85, 0.55), (0x7A5CFF, 0.88, 0.75, 0.6), (0x1FA6B8, 0.5, 0.15, 0.5), (0xE2367A, 0.95, 0.05, 0.4)]
			: [(0xFFB48A, 0.1, 0.85, 0.55), (0xB9A6FF, 0.9, 0.8, 0.6), (0x8FD3E8, 0.45, 0.1, 0.5), (0xFF8FB1, 0.95, 0.05, 0.4)]
	}

	var body: some View {
		GeometryReader { geo in
			let size = max(geo.size.width, geo.size.height)
			ZStack {
				LinearGradient(colors: base.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
				ForEach(blobs.indices, id: \.self) { i in
					let blob = blobs[i]
					RadialGradient(colors: [Color(hex: blob.color).opacity(dark ? 0.55 : 0.75), .clear],
						center: UnitPoint(x: blob.x, y: blob.y), startRadius: 0, endRadius: blob.radius * size)
				}
			}
		}
	}
}
