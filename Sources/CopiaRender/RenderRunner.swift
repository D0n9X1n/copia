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

			let model = StripModel(clips: scene.clips(assets.mixed, assets.extremes), animator: .immediate)
			let thumbnails = ThumbnailCache()
			let root = StripView(model: model, focus: SearchFocus(), thumbnails: thumbnails, now: { Fixtures.now })
				.environment(\.copiaOverrides, scene.overrides)
			panel.host.rootView = AnyView(root)
			panel.setFrame(PanelLayout.windowFrame(in: visible), display: true)
			panel.orderFrontRegardless()
			model.open()
			model.animateIn()
			await scene.prepare(model)
			try await Task.sleep(for: .milliseconds(450))

			let url = output.appendingPathComponent("\(scene.name).png")
			let region = PanelLayout.stripFrame(in: visible).insetBy(dx: -28, dy: -28).intersection(visible)
			try capture(region, on: screen, to: url)
			manifest.append(["scene": scene.name, "file": url.lastPathComponent, "dark": scene.dark,
				"wallpaperDark": scene.wallpaperDark, "frame": NSStringFromRect(panel.frame)])
			print("rendered \(scene.name)")
		}
		let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
		try data.write(to: output.appendingPathComponent("manifest.json"))
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

/// A fixed wallpaper with diagonal bands so the glass blur is visible.
struct Wallpaper: View {
	let dark: Bool
	var body: some View {
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
