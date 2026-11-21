import Testing
import AppKit
import CopiaFixtures
@testable import CopiaUI

/// Draws a test image at 2× with AppKit, so text has real glyph antialiasing.
@MainActor
func scene(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage {
	let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
		space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
	draw(ctx)
	NSGraphicsContext.restoreGraphicsState()
	return ctx.makeImage()!
}

func srgb(_ hex: UInt32) -> SIMD3<Double> { Theme.rgb(hex) }
func fill(_ ctx: CGContext, _ hex: UInt32, _ rect: CGRect) {
	let c = srgb(hex)
	ctx.setFillColor(CGColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1))
	ctx.fill(rect)
}

/// Draws `text` with its line box's bottom-left at `origin` (pixels, bottom-left origin); returns the box in points, top-left origin.
@MainActor
func drawText(_ text: String, hex: UInt32, at origin: CGPoint, imageHeight: Int) -> CGRect {
	let c = srgb(hex)
	let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .medium),
		.foregroundColor: NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)]
	let size = (text as NSString).size(withAttributes: attrs)
	(text as NSString).draw(at: origin, withAttributes: attrs)
	return CGRect(x: origin.x / 2, y: (CGFloat(imageHeight) - origin.y - size.height) / 2, width: size.width / 2, height: size.height / 2)
}

@MainActor
@Suite struct ContrastCheckTests {
	@Test func theFormulaMatchesTheThemes() {
		for (a, b) in [(0x1D1D1F, 0xFFFFFF), (0x6E6E73, 0xF2F2F7), (0xA1A1A6, 0x535353), (0x007AFF, 0x000000)] as [(UInt32, UInt32)] {
			#expect(abs(ContrastCheck.contrast(srgb(a), srgb(b)) - Theme.contrast(srgb(a), srgb(b))) < 1e-9)
		}
	}

	@Test(arguments: [(0x6E6E73 as UInt32, 0xB4B4B8 as UInt32), (0xA1A1A6, 0x535353), (0x1D1D1F, 0xE8E8ED)])
	func textOnAPlainBackingMeasuresItsInkAgainstIt(ink: UInt32, backing: UInt32) {
		var box = CGRect.zero
		let image = scene(width: 320, height: 90) { ctx in
			fill(ctx, backing, CGRect(x: 0, y: 0, width: 320, height: 90))
			box = drawText("9 items · 2 of 9", hex: ink, at: CGPoint(x: 24, y: 30), imageHeight: 90)
		}
		let measured = ContrastCheck.text(in: ContrastCheck.Bitmap(image), box: box, scale: 2)
		let expected = ContrastCheck.contrast(srgb(ink), srgb(backing))
		#expect(abs(measured - expected) / expected < 0.03, "measured \(measured), expected \(expected)")
	}

	@Test func textIsMeasuredAgainstTheBackingNearestItsInk() {
		var box = CGRect.zero
		let image = scene(width: 320, height: 90) { ctx in
			fill(ctx, 0xE0E0E0, CGRect(x: 0, y: 0, width: 320, height: 90))
			fill(ctx, 0x8A8A8A, CGRect(x: 0, y: 0, width: 160, height: 90))
			box = drawText("Nothing copied yet", hex: 0x1D1D1F, at: CGPoint(x: 24, y: 30), imageHeight: 90)
		}
		let measured = ContrastCheck.text(in: ContrastCheck.Bitmap(image), box: box, scale: 2)
		let worst = ContrastCheck.contrast(srgb(0x1D1D1F), srgb(0x8A8A8A))
		#expect(abs(measured - worst) / worst < 0.03, "measured \(measured), expected \(worst)")
	}

	/// A 3 pt ring (6 px) whose outer edge is `ring`, with `outside` around it and `gap` between it and the card.
	func lensImage(stroke: UInt32, outside: UInt32, gap: UInt32) -> (CGImage, CGRect) {
		let ring = CGRect(x: 40, y: 30, width: 200, height: 120)  // points, top-left origin
		let image = scene(width: 560, height: 360) { ctx in
			fill(ctx, outside, CGRect(x: 0, y: 0, width: 560, height: 360))
			let px = CGRect(x: ring.minX * 2, y: 360 - ring.maxY * 2, width: ring.width * 2, height: ring.height * 2)
			fill(ctx, stroke, px)
			fill(ctx, gap, px.insetBy(dx: 6, dy: 6))
			fill(ctx, 0xFFFFFF, px.insetBy(dx: 10, dy: 10))
		}
		return (image, ring)
	}

	@Test func theLensRingIsMeasuredAgainstBothNeighbors() {
		let (glassy, ring) = lensImage(stroke: 0x0A84FF, outside: 0x6B6B6B, gap: 0x6B6B6B)
		let low = ContrastCheck.lens(in: ContrastCheck.Bitmap(glassy), ring: ring, scale: 2)
		#expect(abs(low - ContrastCheck.contrast(srgb(0x0A84FF), srgb(0x6B6B6B))) < 0.05)
		#expect(low < ContrastCheck.lensMinimum)

		let (haloed, _) = lensImage(stroke: 0x0A84FF, outside: 0x000000, gap: 0x000000)
		let high = ContrastCheck.lens(in: ContrastCheck.Bitmap(haloed), ring: ring, scale: 2)
		#expect(abs(high - ContrastCheck.contrast(srgb(0x0A84FF), srgb(0x000000))) < 0.05)

		// A dim inner gap fails even when the outside passes.
		let (gapped, _) = lensImage(stroke: 0x0A84FF, outside: 0x000000, gap: 0x5A6E8C)
		#expect(ContrastCheck.lens(in: ContrastCheck.Bitmap(gapped), ring: ring, scale: 2) < ContrastCheck.lensMinimum)
	}

	@Test func checkReadsTheManifestAndFlagsEachProbe() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-contrast-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		var good = CGRect.zero, bad = CGRect.zero
		let text = scene(width: 320, height: 180) { ctx in
			fill(ctx, 0xE8E8ED, CGRect(x: 0, y: 0, width: 320, height: 180))
			good = drawText("9 items", hex: 0x1D1D1F, at: CGPoint(x: 24, y: 110), imageHeight: 180)
			bad = drawText("2 of 9", hex: 0xA1A1A6, at: CGPoint(x: 24, y: 30), imageHeight: 180)
		}
		let (lens, ring) = lensImage(stroke: 0x0A84FF, outside: 0x6B6B6B, gap: 0x6B6B6B)
		try write(text, to: dir.appendingPathComponent("text.png"))
		try write(lens, to: dir.appendingPathComponent("lens.png"))
		let manifest: [[String: Any]] = [
			["scene": "text", "file": "text.png", "regionWidth": 160, "probes": [
				ContrastCheck.Probe(kind: .text, name: "good", rect: good).json,
				ContrastCheck.Probe(kind: .text, name: "bad", rect: bad).json]],
			["scene": "lens", "file": "lens.png", "regionWidth": 280, "probes": [
				ContrastCheck.Probe(kind: .lens, name: "lens", rect: ring).json]],
			["scene": "shell", "file": "shell.png"],
		]
		try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))

		let results = try ContrastCheck.check(directory: dir)
		#expect(results.map(\.probe) == ["good", "bad", "lens"])
		#expect(results.map(\.passes) == [true, false, false])
		#expect(results.first { $0.probe == "lens" }?.minimum == 3)
		#expect(results.first { $0.probe == "good" }?.minimum == 4.5)
		#expect(ContrastCheck.exitCode(results) == 1)
		#expect(ContrastCheck.exitCode(results.filter(\.passes)) == 0)
		// Measuring nothing must not pass.
		#expect(ContrastCheck.exitCode([]) == 1)
	}

	func write(_ image: CGImage, to url: URL) throws {
		let rep = NSBitmapImageRep(cgImage: image)
		try #require(rep.representation(using: .png, properties: [:])).write(to: url)
	}
}
