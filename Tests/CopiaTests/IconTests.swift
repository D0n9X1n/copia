import Testing
import Foundation
import CoreGraphics
import CopiaFixtures

/// The app icon's source layers, as the brief describes them.
@Suite struct IconTests {
	static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGImage {
		let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
		ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
		return ctx.makeImage()!
	}

	/// RGBA of the pixel at (x, y) counted from the top-left.
	static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
		let data = image.dataProvider!.data! as Data
		let offset = y * image.bytesPerRow + x * 4
		return Array(data[offset..<offset + 4])
	}

	/// The review sheet shows each icon at exactly 1024, 128, 32 and 16 px, on a light row and a dark row.
	@Test func theIconReviewSheetShowsEverySizeOnLightAndDark() throws {
		#expect(IconReview.sizes == [1024, 128, 32, 16])
		let sheet = try #require(IconReview.sheet(light: Self.solid(1, 0, 0), dark: Self.solid(0, 0, 1)))
		#expect(CGSize(width: sheet.width, height: sheet.height) == IconReview.size)
		#expect(IconReview.frames.count == 8)
		for frame in IconReview.frames {
			#expect(Int(frame.rect.width) == frame.size && Int(frame.rect.height) == frame.size)
			let inside = Self.pixel(sheet, Int(frame.rect.midX), Int(frame.rect.midY))
			#expect(inside == (frame.dark ? [0, 0, 255, 255] : [255, 0, 0, 255]), "\(frame)")
			let corner = Self.pixel(sheet, Int(frame.rect.minX), Int(frame.rect.minY))
			#expect(corner == inside, "\(frame) top-left pixel")
			let outside = Self.pixel(sheet, Int(frame.rect.minX) - 1, Int(frame.rect.minY))
			#expect(outside == (frame.dark ? IconReview.darkBackground : IconReview.lightBackground), "\(frame) left neighbor")
		}
	}
	static let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		.appendingPathComponent("Resources/AppIcon.icon/Assets")

	/// The front card's header is persimmon at 18%, not an opaque band.
	@Test func theFrontCardHeaderIsAnEighteenPercentPersimmonBand() throws {
		let svg = try String(contentsOf: Self.assets.appendingPathComponent("card-front-details.svg"), encoding: .utf8)
		let rects = svg.matches(of: /<rect\b[^>]*>/).map { String($0.output) }
		let header = try #require(rects.first { $0.contains("fill=\"#FF6A3D\"") }, "no persimmon rect in \(rects)")
		#expect(header.contains("height=\"104\""))
		#expect(header.contains("fill-opacity=\"0.18\""), "\(header)")
	}
}
