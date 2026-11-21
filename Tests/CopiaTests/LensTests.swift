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
	static func alpha(at points: [CGPoint], removing: Bool = false) throws -> [Double] {
		_ = NSApplication.shared
		// Both lenses in one image: a second ImageRenderer of the same view can return the first render's content.
		func tile(_ removing: Bool) -> some View {
			LensRing(removing: removing).frame(width: Theme.cardSize.width, height: Theme.cardSize.height).padding(margin)
		}
		let renderer = ImageRenderer(content: HStack(spacing: 0) { tile(false); tile(true) })
		renderer.scale = 1
		let image = try #require(renderer.cgImage)
		let (width, height) = (image.width, image.height)
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		return points.map { point in
			let (x, y) = (Int(point.x + (removing ? Theme.cardSize.width + 2 * margin : 0)), Int(point.y))
			return Double(pixels[(y * width + x) * 4 + 3]) / 255
		}
	}

	static var points: [CGPoint] {
		let midY = margin + Theme.cardSize.height / 2
		let outer = margin - Theme.lensOutset - Theme.lensHaloWidth
		return [
			CGPoint(x: outer + 1, y: midY),                          // halo
			CGPoint(x: outer + Theme.lensHaloWidth + 1.5, y: midY),  // accent ring
			CGPoint(x: margin - 1, y: midY),                         // the gap between ring and card
			CGPoint(x: margin + Theme.cardSize.width / 2, y: midY),  // behind the card's center
		]
	}

	@Test func theLensIsAThreePointAccentStrokeOverATwelvePercentAccentFill() throws {
		let alphas = try Self.alpha(at: Self.points)
		#expect(alphas[0] > 0.99, "halo \(alphas)")
		#expect(alphas[1] > 0.99, "ring \(alphas)")
		#expect(alphas[2] > 0.08 && alphas[2] < 0.16, "gap \(alphas)")
		#expect(alphas[3] > 0.08 && alphas[3] < 0.16, "center \(alphas)")
	}

	@Test func aDeletingCardsLensFadesWithItSoNoBlockShows() throws {
		let alphas = try Self.alpha(at: Self.points, removing: true)
		#expect(alphas.allSatisfy { $0 < 0.01 }, "\(alphas)")
	}
}
