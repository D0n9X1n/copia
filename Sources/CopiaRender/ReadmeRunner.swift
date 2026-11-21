import AppKit
import ImageIO
import SwiftUI
import CopiaCore
import CopiaUI
import CopiaFixtures

/// Renders the README's product shots: fixture data only, over a generated wallpaper that covers the whole capture.
@MainActor
enum ReadmeRunner {
	/// The wallpaper sits above the menu bar and notifications, so a capture can only contain Copia-owned windows.
	static let wallpaperLevel = NSWindow.Level.screenSaver
	/// Strip width for the feature tiles: two cards.
	static let tileStrip = CGSize(width: PanelLayout.contentWidth(count: 2), height: Theme.panelHeight)
	static let tilePadding: CGFloat = 32

	static func run(output: URL) async throws {
		try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
		let work = FileManager.default.temporaryDirectory.appendingPathComponent("copia-readme-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: work) }
		let assets = try FixtureAssets.prepare(in: work.appendingPathComponent("assets"))
		let icons = try AppIcons.images(in: work)
		try AppIcons.writeReadmeIcons(from: work, to: output)
		guard let screen = NSScreen.screens.first else { throw RenderRunner.RenderError.noScreen }

		let wallpaper = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
		wallpaper.level = wallpaperLevel
		wallpaper.isReleasedWhenClosed = false
		let panel = StripPanel()
		panel.level = wallpaperLevel + 2
		defer { panel.orderOut(nil); wallpaper.orderOut(nil) }

		/// A stage of `size` points at the top-left of the main display, in AppKit coordinates.
		func stage(_ size: CGSize) -> CGRect {
			CGRect(x: screen.frame.minX, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
		}
		func cover(_ region: CGRect, dark: Bool) {
			wallpaper.contentView = NSHostingView(rootView: Wallpaper(dark: dark, aurora: true))
			wallpaper.setFrame(region, display: true)
			wallpaper.orderFrontRegardless()
		}

		var mixed = assets.mixed
		// The link card points at Copia itself rather than at a real third-party page.
		mixed[2].text = "Copia: clipboard history for macOS"
		mixed[2].meta = "github.com"
		mixed[2].url = URL(string: "https://github.com/D0n9X1n/copia")

		for dark in [false, true] {
			let mode = dark ? "dark" : "light"
			NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

			// Hero: a document window with the strip open below it.
			let hero = stage(CGSize(width: 1440, height: 900))
			cover(hero, dark: dark)
			let doc = RenderRunner.window(DocMock(), title: "", hiddenTitle: true, level: wallpaperLevel + 1)
			doc.setFrameOrigin(NSPoint(x: hero.midX - doc.frame.width / 2, y: hero.maxY - 64 - doc.frame.height))
			doc.orderFrontRegardless()
			try await RenderRunner.showStrip(Scene(name: "hero", dark: dark), clips: mixed, in: hero, panel: panel)
			try shoot(hero, name: "hero-\(mode)", width: 1800, radius: 28, output: output, work: work, screen: screen)
			doc.orderOut(nil)

			// Feature tiles: a two-card strip with wallpaper around it.
			for tile in tiles(mixed) {
				let size = CGSize(width: tileStrip.width + 2 * tilePadding, height: tileStrip.height + 2 * tilePadding)
				let region = stage(size)
				cover(region, dark: dark)
				// stripFrame insets the strip by panelInset inside the visible frame.
				let visible = region.insetBy(dx: tilePadding - Theme.panelInset, dy: tilePadding - Theme.panelInset)
				var scene = Scene(name: tile.name, dark: dark)
				scene.prepare = tile.prepare
				try await RenderRunner.showStrip(scene, clips: tile.clips, in: visible, panel: panel)
				try shoot(region, name: "\(tile.name)-\(mode)", width: Int(size.width * 2), radius: 24,
					output: output, work: work, screen: screen)
			}
			panel.orderOut(nil)

			wallpaper.orderOut(nil)
			try await shootWindows(dark: dark, icon: dark ? icons.dark : icons.light, name: "windows-\(mode)", output: output, work: work)
		}
	}

	/// Onboarding and Settings side by side. A regular-policy app is needed for windows to draw as active,
	/// and its windows may open on another Space, so each window is captured on its own and laid over the wallpaper.
	static func shootWindows(dark: Bool, icon: NSImage, name: String, output: URL, work: URL) async throws {
		let stage = CGSize(width: 1440, height: 720), scale: CGFloat = 2, gap: CGFloat = 56
		let shell = ShellModel()
		shell.ignoredApps = ["com.apple.Passwords", "com.1password.1password"]
		let windows = [
			RenderRunner.window(OnboardingView(model: ShellModel(), icon: icon), title: "", hiddenTitle: true, level: .floating + 1),
			RenderRunner.settingsWindow(model: shell, tab: .general, level: .floating + 1),
		]
		NSApp.setActivationPolicy(.regular)
		defer { windows.forEach { $0.orderOut(nil) }; NSApp.setActivationPolicy(.accessory) }
		var shots: [CGImage] = []
		for window in windows {
			window.makeKeyAndOrderFront(nil)
			NSApp.activate()
			try await Task.sleep(for: .milliseconds(700))
			let url = work.appendingPathComponent("\(name)-\(shots.count).png")
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
			// No -o: the window keeps its shadow, which the composite needs.
			process.arguments = ["-x", "-l\(window.windowNumber)", url.path]
			try process.run()
			process.waitUntilExit()
			guard process.terminationStatus == 0, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
				let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw RenderRunner.RenderError.captureFailed(name) }
			shots.append(image)
			window.orderOut(nil)
		}

		let renderer = ImageRenderer(content: Aurora(dark: dark).frame(width: stage.width, height: stage.height))
		renderer.scale = scale
		guard let background = renderer.cgImage else { throw RenderRunner.RenderError.captureFailed("\(name) wallpaper") }
		let ctx = try AppIcons.context(width: Int(stage.width * scale), height: Int(stage.height * scale))
		ctx.draw(background, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
		// A capture is the window plus its shadow, which reaches further below, so place each by its opaque part.
		var x = (stage.width - (windows[0].frame.width + gap + windows[1].frame.width)) / 2
		for (window, shot) in zip(windows, shots) {
			let body = try opaqueBounds(shot)
			let center = CGPoint(x: (x + window.frame.width / 2) * scale, y: stage.height / 2 * scale)
			ctx.draw(shot, in: CGRect(x: center.x - body.midX, y: center.y - body.midY, width: CGFloat(shot.width), height: CGFloat(shot.height)))
			x += window.frame.width + gap
		}
		let raw = work.appendingPathComponent("\(name)-raw.png")
		try AppIcons.write(ctx, to: raw)
		try finish(raw, to: output.appendingPathComponent("\(name).png"), width: 1800, radius: 28)
		print("rendered readme \(name)")
	}

	struct Tile {
		let name: String
		let clips: [Clip]
		var prepare: @MainActor (StripModel) async -> Void = { _ in }
	}

	static func tiles(_ mixed: [Clip]) -> [Tile] {
		[
			Tile(name: "search", clips: mixed, prepare: { m in m.query = "the" }),
			Tile(name: "previews", clips: [mixed[2], mixed[3]]),
			Tile(name: "quick-paste", clips: [mixed[1], mixed[4]], prepare: { m in m.commandHeld = true }),
			Tile(name: "undo", clips: [mixed[0], mixed[6], mixed[5]], prepare: { m in await m.deleteSelected() }),
		]
	}

	/// Captures `region`, then scales it to `width` pixels with rounded corners.
	static func shoot(_ region: CGRect, name: String, width: Int, radius: CGFloat, output: URL, work: URL, screen: NSScreen) throws {
		let raw = work.appendingPathComponent("\(name)-raw.png")
		try RenderRunner.capture(region, on: screen, to: raw)
		try finish(raw, to: output.appendingPathComponent("\(name).png"), width: width, radius: radius)
		print("rendered readme \(name)")
	}

	/// The fully opaque part of `image` in Core Graphics pixel coordinates: the window without its shadow.
	static func opaqueBounds(_ image: CGImage) throws -> CGRect {
		let ctx = try AppIcons.context(width: image.width, height: image.height)
		ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		guard let data = ctx.data else { throw RenderRunner.RenderError.captureFailed("opaque bounds") }
		let pixels = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * ctx.height)
		var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
		for row in 0..<ctx.height {
			for col in 0..<ctx.width where pixels[row * ctx.bytesPerRow + col * 4 + 3] == 255 {
				minX = min(minX, col); maxX = max(maxX, col); minY = min(minY, row); maxY = max(maxY, row)
			}
		}
		guard maxX >= 0 else { throw RenderRunner.RenderError.captureFailed("opaque bounds") }
		// Rows in memory run top-down; flip to Core Graphics' bottom-up origin.
		return CGRect(x: minX, y: ctx.height - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
	}

	static func finish(_ source: URL, to url: URL, width: Int, radius: CGFloat) throws {
		guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
			let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw RenderRunner.RenderError.captureFailed(source.lastPathComponent) }
		let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
		let rect = CGRect(x: 0, y: 0, width: width, height: height)
		let ctx = try AppIcons.context(width: width, height: height)
		ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
		ctx.clip()
		ctx.interpolationQuality = .high
		ctx.draw(image, in: rect)
		try AppIcons.write(ctx, to: url)
	}
}

/// Copia's light Garland artwork, shared by both appearances.
enum AppIcons {
	static let ictool = ProcessInfo.processInfo.environment["ICTOOL"]
		?? "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

	/// Exports both native renditions for review; user-facing content uses `Default` in both modes.
	static func export(to directory: URL) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		for rendition in ["Default", "Dark"] {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: ictool)
			process.arguments = ["Resources/AppIcon.icon", "--export-image", "--output-file",
				directory.appendingPathComponent("icon-\(rendition).png").path, "--platform", "macOS",
				"--rendition", rendition, "--width", "512", "--height", "512", "--scale", "2"]
			process.standardOutput = FileHandle.nullDevice
			try process.run()
			process.waitUntilExit()
			guard process.terminationStatus == 0 else { throw RenderRunner.RenderError.captureFailed("icon \(rendition)") }
		}
	}

	/// The same light icon on the macOS icon grid for both onboarding appearances.
	@MainActor
	static func images(in directory: URL) throws -> (light: NSImage, dark: NSImage) {
		try export(to: directory)
		func load(_ rendition: String) throws -> NSImage {
			let cg = try padded(directory.appendingPathComponent("icon-\(rendition).png"), pixels: 512)
			return NSImage(cgImage: cg, size: NSSize(width: 256, height: 256))
		}
		let light = try load("Default")
		return (light, light)
	}

	/// The README header icons: 256 px, on the icon grid with a soft shadow.
	static func writeReadmeIcons(from directory: URL, to output: URL) throws {
		for (rendition, mode) in [("Default", "light"), ("Default", "dark")] {
			let cg = try padded(directory.appendingPathComponent("icon-\(rendition).png"), pixels: 256)
			let ctx = try context(width: cg.width, height: cg.height)
			ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
			try write(ctx, to: output.appendingPathComponent("icon-\(mode).png"))
		}
	}

	/// Draws the full-bleed export at 824/1024 of the canvas, as macOS app icons sit, with a soft drop shadow.
	static func padded(_ url: URL, pixels: Int) throws -> CGImage {
		guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
			let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw RenderRunner.RenderError.captureFailed(url.lastPathComponent) }
		let ctx = try context(width: pixels, height: pixels)
		let side = CGFloat(pixels) * 824 / 1024
		let scale = CGFloat(pixels) / 1024
		ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.3))
		ctx.interpolationQuality = .high
		ctx.draw(image, in: CGRect(x: (CGFloat(pixels) - side) / 2, y: (CGFloat(pixels) - side) / 2 + 6 * scale, width: side, height: side))
		guard let out = ctx.makeImage() else { throw RenderRunner.RenderError.captureFailed(url.lastPathComponent) }
		return out
	}

	static func context(width: Int, height: Int) throws -> CGContext {
		guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { throw RenderRunner.RenderError.captureFailed("context") }
		return ctx
	}

	static func write(_ ctx: CGContext, to url: URL) throws {
		guard let image = ctx.makeImage(),
			let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
		else { throw RenderRunner.RenderError.captureFailed(url.lastPathComponent) }
		CGImageDestinationAddImage(dest, image, nil)
		guard CGImageDestinationFinalize(dest) else { throw RenderRunner.RenderError.captureFailed(url.lastPathComponent) }
	}
}

/// A plain document window for the hero shot, so the strip is seen over an app the way users meet it.
struct DocMock: View {
	private let items: [(String, Bool)] = [
		("Final icon in Icon Composer", true),
		("Strip opens in under 100 ms", true),
		("Release notes with the new shortcuts", false),
		("Record the launch video", false),
	]

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("Launch checklist").font(.system(size: 30, weight: .bold))
			Text("Copia 0.0.1 · Friday").font(.system(size: 15)).foregroundStyle(.secondary)
			Divider().padding(.vertical, 6)
			ForEach(items.indices, id: \.self) { i in
				HStack(spacing: 12) {
					Image(systemName: items[i].1 ? "checkmark.circle.fill" : "circle")
						.font(.system(size: 18))
						.foregroundStyle(items[i].1 ? Color(hex: 0xFF6A3D) : Color.secondary)
					Text(items[i].0).font(.system(size: 17))
				}
			}
			Spacer()
		}
		.padding(.horizontal, 44)
		.padding(.top, 60)
		.frame(width: 760, height: 460, alignment: .topLeading)
		.background(Color(nsColor: .textBackgroundColor))
	}
}
