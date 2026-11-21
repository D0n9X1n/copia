import Testing
import AppKit
import SwiftUI
@testable import CopiaUI

/// The lens drawn alone around a card-sized slot, read back as pixels.
@MainActor
@Suite struct LensTests {
	/// Room around the card for the lens to overhang into.
	static let margin: CGFloat = 11

	/// Alpha (0...1) at each point, in points from the top-left of the rendered image.
	static func alpha(at points: [CGPoint]) throws -> [Double] {
		_ = NSApplication.shared
		let renderer = ImageRenderer(content: LensRing()
			.frame(width: Theme.cardSize.width, height: Theme.cardSize.height)
			.padding(margin))
		renderer.scale = 1
		let image = try #require(renderer.cgImage)
		let (width, height) = (image.width, image.height)
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		return points.map { point in
			let (x, y) = (Int(point.x), Int(point.y))
			return Double(pixels[(y * width + x) * 4 + 3]) / 255
		}
	}

	@Test func theLensIsARingSoADeletedCardFadesToGlassNotToASolidBlock() throws {
		let midY = Self.margin + Theme.cardSize.height / 2
		let outer = Self.margin - Theme.lensOutset - Theme.lensHaloWidth
		let alphas = try Self.alpha(at: [
			CGPoint(x: outer + 1, y: midY),                          // halo
			CGPoint(x: outer + Theme.lensHaloWidth + 1.5, y: midY),  // accent ring
			CGPoint(x: Self.margin - 1, y: midY),                    // the gap between ring and card
			CGPoint(x: Self.margin + 9, y: midY),                    // inside the card's edge
			CGPoint(x: Self.margin + Theme.cardSize.width / 2, y: midY), // the card's center
		])
		#expect(alphas[0] > 0.99, "halo \(alphas)")
		#expect(alphas[1] > 0.99, "ring \(alphas)")
		#expect(alphas[2] > 0.99, "gap \(alphas)")
		#expect(alphas[3] == 0, "inside \(alphas)")
		#expect(alphas[4] == 0, "center \(alphas)")
	}
}
