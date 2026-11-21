import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CopiaCore

/// Writes deterministic preview images to disk so fixture cards show real thumbnails.
public enum FixtureAssets {
	/// Generates the images into `directory` and returns `Fixtures.mixed` + `Fixtures.extremes` with ready previews.
	public static func prepare(in directory: URL) throws -> (mixed: [Clip], extremes: [Clip]) {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let screenshot = directory.appendingPathComponent("screenshot.png")
		let hero = directory.appendingPathComponent("link-hero.png")
		let panorama = directory.appendingPathComponent("panorama.png")
		let logo = directory.appendingPathComponent("logo.png")
		try write(drawScreenshot(width: 960, height: 640), to: screenshot)
		try write(drawHero(width: 768, height: 400), to: hero)
		try write(drawLandscape(width: 960, height: 960), to: panorama)
		try write(drawLogo(side: 480), to: logo)

		var mixed = Fixtures.mixed
		mixed[2].preview = .ready(hero)
		mixed[3].preview = .ready(screenshot)
		var extremes = Fixtures.extremes
		extremes[6].preview = .ready(panorama)
		extremes[7].preview = .ready(logo)
		return (mixed, extremes)
	}

	static func context(_ width: Int, _ height: Int) -> CGContext {
		CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	}

	static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
		CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
			blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
	}

	static func gradient(_ ctx: CGContext, _ from: UInt32, _ to: UInt32, _ rect: CGRect, vertical: Bool = true) {
		let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(from), color(to)] as CFArray, locations: [0, 1])!
		ctx.saveGState()
		ctx.clip(to: rect)
		ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY),
			end: vertical ? CGPoint(x: rect.minX, y: rect.minY) : CGPoint(x: rect.maxX, y: rect.minY), options: [])
		ctx.restoreGState()
	}

	static func roundRect(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ fill: CGColor) {
		ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
		ctx.setFillColor(fill)
		ctx.fillPath()
	}

	/// A dark-mode app window with a sidebar and content blocks.
	static func drawScreenshot(width: Int, height: Int) -> CGImage {
		let ctx = context(width, height)
		let w = CGFloat(width), h = CGFloat(height)
		gradient(ctx, 0x5B6CFF, 0xB06AB3, CGRect(x: 0, y: 0, width: w, height: h), vertical: false)
		let window = CGRect(x: 60, y: 50, width: w - 120, height: h - 100)
		roundRect(ctx, window, 18, color(0x1E1F24))
		roundRect(ctx, CGRect(x: window.minX, y: window.maxY - 44, width: window.width, height: 44), 18, color(0x2A2B31))
		for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
			ctx.setFillColor(color(UInt32(c)))
			ctx.fillEllipse(in: CGRect(x: window.minX + 18 + CGFloat(i) * 22, y: window.maxY - 28, width: 13, height: 13))
		}
		roundRect(ctx, CGRect(x: window.minX + 14, y: window.minY + 14, width: 180, height: window.height - 72), 10, color(0x26272D))
		for i in 0..<7 {
			roundRect(ctx, CGRect(x: window.minX + 30, y: window.maxY - 90 - CGFloat(i) * 46, width: CGFloat(110 + (i * 23) % 40), height: 14), 7,
				color(i == 1 ? 0x0A84FF : 0x4A4B52))
		}
		let content = CGRect(x: window.minX + 214, y: window.minY + 14, width: window.width - 228, height: window.height - 72)
		roundRect(ctx, CGRect(x: content.minX, y: content.maxY - 160, width: content.width, height: 150), 14, color(0x0A84FF, 0.9))
		for i in 0..<3 {
			roundRect(ctx, CGRect(x: content.minX + CGFloat(i) * (content.width / 3 + 4), y: content.minY + 120,
				width: content.width / 3 - 8, height: 170), 12, color([0x30D158, 0xFF9F0A, 0xBF5AF2][i], 0.85))
		}
		for i in 0..<4 {
			roundRect(ctx, CGRect(x: content.minX, y: content.minY + 16 + CGFloat(i) * 24, width: content.width * [0.9, 0.7, 0.8, 0.5][i], height: 12), 6, color(0x4A4B52))
		}
		return ctx.makeImage()!
	}

	/// A link hero image: soft gradient with layered glass-like cards.
	static func drawHero(width: Int, height: Int) -> CGImage {
		let ctx = context(width, height)
		let w = CGFloat(width), h = CGFloat(height)
		gradient(ctx, 0xFFB86C, 0xFF5E7E, CGRect(x: 0, y: 0, width: w, height: h), vertical: false)
		ctx.setFillColor(color(0xFFFFFF, 0.18))
		ctx.fillEllipse(in: CGRect(x: w * 0.55, y: -h * 0.3, width: w * 0.7, height: w * 0.7))
		for i in 0..<3 {
			let r = CGRect(x: w * 0.12 + CGFloat(i) * 70, y: h * 0.18 + CGFloat(i) * 26, width: w * 0.42, height: h * 0.5)
			roundRect(ctx, r, 24, color(0xFFFFFF, 0.35 + Double(i) * 0.2))
		}
		return ctx.makeImage()!
	}

	/// A landscape: sky, sun and layered hills.
	static func drawLandscape(width: Int, height: Int) -> CGImage {
		let ctx = context(width, height)
		let w = CGFloat(width), h = CGFloat(height)
		gradient(ctx, 0x8EC5FC, 0xE0C3FC, CGRect(x: 0, y: 0, width: w, height: h))
		ctx.setFillColor(color(0xFFF4D6))
		ctx.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.58, width: w * 0.18, height: w * 0.18))
		for (i, c) in [0x6A8CAF, 0x4F7396, 0x2F5577].enumerated() {
			let path = CGMutablePath()
			let base = h * (0.45 - CGFloat(i) * 0.12)
			path.move(to: CGPoint(x: 0, y: 0))
			path.addLine(to: CGPoint(x: 0, y: base))
			for x in stride(from: 0, through: w, by: 8) {
				path.addLine(to: CGPoint(x: x, y: base + sin(x / w * .pi * Double(2 + i) + Double(i)) * h * 0.06))
			}
			path.addLine(to: CGPoint(x: w, y: 0))
			ctx.addPath(path)
			ctx.setFillColor(color(UInt32(c)))
			ctx.fillPath()
		}
		return ctx.makeImage()!
	}

	/// A transparent logo: a ring and a dot.
	static func drawLogo(side: Int) -> CGImage {
		let ctx = context(side, side)
		let s = CGFloat(side)
		ctx.setStrokeColor(color(0x5E5CE6))
		ctx.setLineWidth(s * 0.1)
		ctx.strokeEllipse(in: CGRect(x: s * 0.15, y: s * 0.15, width: s * 0.7, height: s * 0.7))
		ctx.setFillColor(color(0xFF375F))
		ctx.fillEllipse(in: CGRect(x: s * 0.4, y: s * 0.4, width: s * 0.2, height: s * 0.2))
		return ctx.makeImage()!
	}

	static func write(_ image: CGImage, to url: URL) throws {
		guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
			throw CocoaError(.fileWriteUnknown)
		}
		CGImageDestinationAddImage(dest, image, nil)
		guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
	}
}
