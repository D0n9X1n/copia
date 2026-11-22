import Testing
import AppKit
import SwiftUI
import CopiaCore
@testable import CopiaUI

/// While a preview loads, the card body shows its type symbol at 30% (design brief, "Preview loading").
@MainActor
@Suite struct CardLoadingTests {
	/// Light-mode luma of the darkest pixel in the card's art area (points, top-left origin).
	static func darkestArt(_ clip: Clip) throws -> Double {
		_ = NSApplication.shared
		let card = ClipCard(clip: clip, tint: Theme.neutralTint, icon: nil, badge: nil, hovered: false, selected: false,
			removing: false, age: ClipCard.relative(clip.timestamp, now: clip.timestamp), highlight: "", thumbnails: ThumbnailCache(), animator: .immediate)
			.environment(\.colorScheme, .light)
		let renderer = ImageRenderer(content: card)
		renderer.scale = 2
		var rendered: CGImage?
		NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { rendered = renderer.cgImage }
		let image = try #require(rendered)
		let (width, height) = (image.width, image.height)
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		// The art area: below the header, above the title or file name.
		var darkest = 255.0
		for y in 56 * 2..<148 * 2 {
			for x in 20 * 2..<196 * 2 {
				let i = (y * width + x) * 4
				let luma = 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
				darkest = min(darkest, luma)
			}
		}
		return darkest
	}

	/// Ink (#1D1D1F) at 30% over the white card or the 6% field reads 176–187; at 45% it reads about 145.
	static let thirtyPercent = 168.0...200.0
	static let missing = URL(fileURLWithPath: "/nonexistent/copia-preview.png")

	@Test func aPendingLinkShowsItsSymbolAtThirtyPercent() throws {
		let link = Clip(id: UUID(), kind: .link, text: "https://example.org/article", timestamp: Date(), preview: .pending,
			url: URL(string: "https://example.org/article"))
		let darkest = try Self.darkestArt(link)
		#expect(Self.thirtyPercent.contains(darkest), "darkest \(darkest)")
	}

	@Test func aLinkWhosePreviewIsStillDecodingShowsItsSymbolAtThirtyPercent() throws {
		let link = Clip(id: UUID(), kind: .link, text: "https://example.org/article", timestamp: Date(),
			preview: .ready(Self.missing), url: URL(string: "https://example.org/article"))
		let darkest = try Self.darkestArt(link)
		#expect(Self.thirtyPercent.contains(darkest), "darkest \(darkest)")
	}

	@Test func aPendingFileShowsItsSymbolAtThirtyPercentNotTheFileIcon() throws {
		let file = Clip(id: UUID(), kind: .file, text: "Design Review.key", timestamp: Date(), preview: .pending,
			fileNames: ["Design Review.key"])
		let darkest = try Self.darkestArt(file)
		#expect(Self.thirtyPercent.contains(darkest), "darkest \(darkest)")
	}
}
