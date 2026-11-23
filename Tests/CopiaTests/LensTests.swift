import Testing
import AppKit
import SwiftUI
import CopiaFixtures
@testable import CopiaUI

extension WindowTests {
	/// The lens drawn alone around a card-sized slot, read back as pixels.
	@MainActor @Suite struct LensTests {}
}

extension WindowTests.LensTests {
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
		// The gap is the opaque halo tinted by the fill, so the ring keeps 3:1 against it on any glass.
		#expect(alphas[2] > 0.99, "gap \(alphas)")
		#expect(alphas[3] > 0.08 && alphas[3] < 0.16, "center \(alphas)")
	}

	@Test func aDeletingCardsLensFadesWithItSoNoBlockShows() throws {
		let alphas = try Self.alpha(at: Self.points, removing: true)
		#expect(alphas.allSatisfy { $0 < 0.01 }, "\(alphas)")
	}
}

extension WindowTests.LensTests {
	@Test func pressMovesTheOnlyOuterRingToTheTargetInTheOwnedWindow() async throws {
		for reduced in [false, true] {
			let host = InputHost(reduced: reduced); defer { host.close() }
			host.panel.setFrameOrigin(try #require(NSScreen.main).visibleFrame.origin); host.panel.alphaValue = 1
			await host.settle()
			func cards() throws -> [AXNode] {
				try ["Notes", "Xcode", "Safari"].map { name in try #require(host.cards.first { $0.label.contains("from \(name),") }) }
			}
			func rings() throws -> [Double] {
				let v = host.panel.host, rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
				v.cacheDisplay(in: v.bounds, to: rep)
				let image = try #require(rep.cgImage), bitmap = ContrastCheck.Bitmap(image)
				return try cards().map { card in
					let rect = CGRect(x: card.frame.midX - host.panel.frame.minX - Theme.cardSize.width / 2,
						y: host.panel.frame.maxY - card.frame.midY - Theme.cardSize.height / 2,
						width: Theme.cardSize.width, height: Theme.cardSize.height).insetBy(dx: -Theme.lensOutset, dy: -Theme.lensOutset)
					// Ring presence: on press the lens is grey until the click's copy lands; either way the ring is there.
					return ContrastCheck.lens(in: bitmap, ring: rect, scale: CGFloat(image.width) / v.bounds.width, percentile: 0.5)
				}
			}
			host.model.selectAllResults(); await host.settle()
			let first = try rings()
			#expect(first[0] > 2 && first[1] < 1.5 && first[2] < 1.5, "\(first)")
			host.mouse(.leftMouseDown, at: try cards()[2]); #expect(host.model.selectedID == Fixtures.mixed[2].id); await host.settle()
			let next = try rings()
			#expect(next[0] < 1.5 && next[1] < 1.5 && next[2] > 2, "reduced=\(reduced) \(next)")
			host.mouse(.leftMouseUp, at: try cards()[2])
			// The release now copies; let that queued write land before the host and its log go away.
			await host.settle()
		}
	}
}
