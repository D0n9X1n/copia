import AppKit
import SwiftUI
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
}

/// Renders each strip state as a real window over a fixed wallpaper and captures it with `screencapture`.
@MainActor
enum RenderRunner {
	/// A 1440×900 "screen" placed at the top-left of the main display.
	static let stage = CGSize(width: 1440, height: 900)

	static func scenes() -> [Scene] {
		var list: [Scene] = []
		for dark in [false, true] {
			for wallpaperDark in [false, true] {
				let suffix = "\(dark ? "dark" : "light")-\(wallpaperDark ? "darkwall" : "brightwall")"
				list.append(Scene(name: "01-mixed-\(suffix)", dark: dark, wallpaperDark: wallpaperDark))
			}
			let mode = dark ? "dark" : "light"
			list.append(Scene(name: "02-selection-mid-\(mode)", dark: dark, prepare: { m in m.select(m.clips[5].id) }))
			list.append(Scene(name: "02-command-badges-\(mode)", dark: dark, prepare: { m in m.commandHeld = true }))
			list.append(Scene(name: "03-search-\(mode)", dark: dark, prepare: { m in m.query = "the" }))
			list.append(Scene(name: "03-no-results-\(mode)", dark: dark, prepare: { m in m.query = "zebra" }))
			list.append(Scene(name: "04-empty-\(mode)", dark: dark, clips: { _, _ in [] }))
			list.append(Scene(name: "04-paused-\(mode)", dark: dark, prepare: { m in m.paused = true }))
			list.append(Scene(name: "05-extremes-\(mode)", dark: dark, clips: { _, e in e + [Fixtures.failed, Fixtures.pending] }))
			list.append(Scene(name: "06-delete-toast-\(mode)", dark: dark, prepare: { m in m.select(m.clips[1].id); await m.deleteSelected() }))
			list.append(Scene(name: "06-ax-toast-\(mode)", dark: dark, prepare: { m in
				m.actions.paste = { _, _, _ in .accessibilityRequired }
				await m.paste(plain: false)
			}))
			list.append(Scene(name: "07-reduce-transparency-\(mode)", dark: dark, overrides: CopiaOverrides(reduceTransparency: true)))
			list.append(Scene(name: "07-increase-contrast-\(mode)", dark: dark, overrides: CopiaOverrides(highContrast: true)))
			list.append(Scene(name: "08-hover-\(mode)", dark: dark, prepare: { m in m.hoveredID = m.clips[2].id }))
			list.append(Scene(name: "08-loading-\(mode)", dark: dark, clips: { mixed, _ in
				var c = mixed; c[2].preview = .pending; c[3].preview = .pending; return c
			}))
		}
		return list
	}

	static func run(output: URL, only: String?) async throws {
		try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
		let assets = try FixtureAssets.prepare(in: output.appendingPathComponent("assets"))
		guard let screen = NSScreen.screens.first else { throw RenderError.noScreen }
		let visible = CGRect(x: screen.frame.minX, y: screen.frame.maxY - stage.height, width: stage.width, height: stage.height)

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
			try await showStrip(scene, clips: scene.clips(assets.mixed, assets.extremes), in: visible, panel: panel)

			let url = output.appendingPathComponent("\(scene.name).png")
			let region = PanelLayout.stripFrame(in: visible).insetBy(dx: -28, dy: -28).intersection(visible)
			try capture(region, on: screen, to: url)
			manifest.append(["scene": scene.name, "file": url.lastPathComponent, "dark": scene.dark,
				"wallpaperDark": scene.wallpaperDark, "frame": NSStringFromRect(panel.frame)])
			print("rendered \(scene.name)")
		}
		if only.map({ "shell".contains($0) || $0.hasPrefix("1") }) ?? true {
			manifest += try await renderShell(output: output, screen: screen, stage: visible, wallpaper: wallpaper)
		}
		let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
		try data.write(to: output.appendingPathComponent("manifest.json"))
	}

	/// Shows `scene` in the strip and waits until every visible preview has decoded,
	/// so no capture shows a loading placeholder by accident.
	@discardableResult
	static func showStrip(_ scene: Scene, clips: [Clip], in visible: CGRect, panel: StripPanel) async throws -> StripModel {
		let model = StripModel(clips: clips, animator: .immediate)
		let thumbnails = ThumbnailCache()
		let root = StripView(model: model, focus: SearchFocus(), thumbnails: thumbnails, now: { Fixtures.now })
			.environment(\.copiaOverrides, scene.overrides)
		panel.host.rootView = AnyView(root)
		panel.setFrame(PanelLayout.windowFrame(in: visible), display: true)
		panel.orderFrontRegardless()
		model.open()
		model.animateIn()
		await scene.prepare(model)
		let expected = model.visibleClips.prefix(12).compactMap { clip -> URL? in
			if case let .ready(url) = clip.preview { return url }
			return nil
		}
		for _ in 0..<200 where !expected.allSatisfy({ thumbnails.cached($0) != nil }) {
			try await Task.sleep(for: .milliseconds(50))
		}
		try await Task.sleep(for: .milliseconds(450))
		// As AppController does on open: the first shadow was taken while the cards sat 56 pt low.
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
				let view = SettingsView(model: shell, initialTab: tab)
				rows.append(try await capture(view, title: "Copia Settings", name: "10-settings-\(tab.rawValue.lowercased())-\(mode)",
					output: output, stage: stage, screen: screen, hiddenTitle: false))
			}
			for (index, step) in OnboardingStep.allCases.enumerated() {
				for granted in [false, true] where step == .accessibility || step == .pasteboard || granted {
					let model = ShellModel()
					model.onboardingStep = index
					model.permissions = PermissionState(accessibility: granted, pasteboard: granted ? .allow : .ask)
					let suffix = step == .accessibility || step == .pasteboard ? (granted ? "-granted" : "-needed") : ""
					rows.append(try await capture(OnboardingView(model: model, icon: appIcon),
						title: "", name: "11-onboarding-\(index + 1)-\(step.title.lowercased().replacingOccurrences(of: " ", with: "-"))\(suffix)-\(mode)", output: output, stage: stage,
						screen: screen, hiddenTitle: true))
				}
			}
		}
		return rows
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

	static func capture<V: View>(_ view: V, title: String, name: String, output: URL, stage: CGRect, screen: NSScreen,
		hiddenTitle: Bool) async throws -> [String: Any] {
		let window = window(view, title: title, hiddenTitle: hiddenTitle, level: .floating + 1)
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

	/// Captures a screen region (AppKit coordinates) so the glass is captured with what it blurs.
	static func capture(_ rect: CGRect, on screen: NSScreen, to url: URL) throws {
		let mainHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
		let r = CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height).integral
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
		process.arguments = ["-x", "-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", url.path]
		try process.run()
		process.waitUntilExit()
		guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
			throw RenderError.captureFailed(url.lastPathComponent)
		}
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
