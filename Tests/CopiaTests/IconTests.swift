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

	/// Garland keeps the chosen violet header and three ink bars on its front card.
	@Test func garlandFrontCardHasItsVioletHeaderAndThreeBars() throws {
		let svg = try String(contentsOf: Self.assets.appendingPathComponent("front-details.svg"), encoding: .utf8)
		let rects = svg.matches(of: /<rect\b[^>]*>/).map { String($0.output) }
		let header = try #require(rects.first { $0.contains("fill=\"#8A3CF0\"") })
		#expect(header.contains("height=\"74\""))
		#expect(!header.contains("opacity"))
		#expect(rects.filter { $0.contains("fill=\"#1D1D1F\"") && $0.contains("fill-opacity=\"0.2\"") }.count == 3)
	}

	@Test func garlandHasThreeYellowPegsAndACurvedLine() throws {
		let pegs = try String(contentsOf: Self.assets.appendingPathComponent("pegs.svg"), encoding: .utf8)
		#expect(pegs.matches(of: /fill="#FFD54A"/).count == 3)
		let line = try String(contentsOf: Self.assets.appendingPathComponent("line.svg"), encoding: .utf8)
		#expect(line.contains("M150 268Q512 420 874 268"))
		#expect(line.contains("stroke-width=\"16\""))
	}

	@Test func garlandPackageReferencesEveryLayerInFrontToBackOrder() throws {
		let data = try Data(contentsOf: Self.assets.deletingLastPathComponent().appendingPathComponent("icon.json"))
		let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		let fill = try #require(json["fill"] as? [String: Any])
		#expect(fill["linear-gradient"] as? [String] == [
			"display-p3:0.71440,0.49450,0.97025,1.00000", "display-p3:0.38364,0.15943,0.80706,1.00000"
		])
		let groups = try #require(json["groups"] as? [[String: Any]])
		let layers = groups.flatMap { $0["layers"] as? [[String: Any]] ?? [] }
		let side = try #require(layers.first { $0["image-name"] as? String == "side-cards.svg" })
		#expect(side["opacity"] as? Double == 0.84)
		let front = try #require(layers.first { $0["image-name"] as? String == "front-details.svg" })
		#expect((front["opacity"] as? Double ?? 1) == 1)
		let frontGroup = try #require(groups.first)
		#expect((frontGroup["opacity"] as? Double ?? 1) == 1)
		let names = layers.compactMap { $0["image-name"] as? String }
		#expect(names == ["pegs.svg", "front-details.svg", "front-card.svg", "side-details.svg", "side-cards.svg", "line.svg"])
		for name in names { #expect(FileManager.default.fileExists(atPath: Self.assets.appendingPathComponent(name).path)) }
		#expect(layers.filter { $0["glass"] as? Bool == true }.compactMap { $0["image-name"] as? String }
			== ["front-card.svg", "side-cards.svg"])
	}

	@Test func garlandHasTwoTiltedSideCardsWithHeadersAndBars() throws {
		let cards = try String(contentsOf: Self.assets.appendingPathComponent("side-cards.svg"), encoding: .utf8)
		let rects = cards.matches(of: /<rect\b[^>]*>/).map { String($0.output) }
		#expect(rects.count == 2)
		for rect in rects {
			#expect(rect.contains("width=\"220\"") && rect.contains("height=\"280\""))
			#expect(rect.contains("fill=\"#FFFFFF\""))
		}
		#expect(cards.contains("rotate(-9 306 330)") && cards.contains("rotate(9 718 330)"))
		let details = try String(contentsOf: Self.assets.appendingPathComponent("side-details.svg"), encoding: .utf8)
		let groups = details.matches(of: /<g transform="rotate\([^"]*\)">.*?<\/g><rect.*?<\/g>/).map { String($0.output) }
		#expect(groups.count == 2)
		for group in groups {
			let details = group.matches(of: /<rect\b[^>]*>/).map { String($0.output) }
			#expect(details.filter { $0.contains("fill=\"#C07BFF\"") && $0.contains("height=\"62\"") }.count == 1)
			#expect(details.filter { $0.contains("fill=\"#1D1D1F\"") && $0.contains("fill-opacity=\"0.2\"") }.count == 2)
		}
	}

}
