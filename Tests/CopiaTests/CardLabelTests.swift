import Testing
import AppKit
import SwiftUI
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

/// The brief's extremes: labels longer after translation tail-truncate and never clip. A deleting card shrinks as it fades.
@MainActor
@Suite(.serialized) struct CardLabelTests {
	func card(_ clip: Clip, growth: Double? = nil, removing: Bool = false, reduced: Bool = false) -> some View {
		ClipCard(clip: clip, tint: Theme.neutralTint, icon: nil, badge: nil, hovered: false, selected: false, removing: removing,
			now: Fixtures.now, highlight: "", thumbnails: ThumbnailCache(), animator: .immediate)
			.environment(\.copiaOverrides, CopiaOverrides(reduceMotion: reduced, labelGrowth: growth))
			.environment(\.colorScheme, .light)
	}

	/// Renders views side by side in one image (a second renderer in one process can return the first one's pixels).
	func render(_ views: [AnyView]) throws -> (pixels: [UInt8], width: Int) {
		_ = NSApplication.shared
		let renderer = ImageRenderer(content: HStack(spacing: 0) { ForEach(views.indices, id: \.self) { views[$0] } })
		renderer.scale = 2
		var rendered: CGImage?
		NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { rendered = renderer.cgImage }
		let image = try #require(rendered)
		var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
		let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
			bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		return (pixels, image.width)
	}

	/// The largest channel difference between two cards' regions (points, top-left origin), card 0 against card 1.
	func difference(_ r: (pixels: [UInt8], width: Int), x: Range<Int>, y: Range<Int>) -> Int {
		let offset = Int(Theme.cardSize.width) * 2
		var worst = 0
		for py in y.lowerBound * 2..<y.upperBound * 2 {
			for px in x.lowerBound * 2..<x.upperBound * 2 {
				for c in 0..<3 {
					let a = Int(r.pixels[(py * r.width + px) * 4 + c]), b = Int(r.pixels[(py * r.width + px + offset) * 4 + c])
					worst = max(worst, abs(a - b))
				}
			}
		}
		return worst
	}

	@Test func grownLabelsAreAtLeastFortyPercentLongerAndKeepTheirStart() {
		for label in ["Text", "Rich Text", "Now", "2m"] {
			let grown = ClipCard.grown(label, by: 1.4)
			#expect(Double(grown.count) >= 1.4 * Double(label.count), "\(grown)")
			#expect(grown.hasPrefix(label))
		}
		#expect(ClipCard.grown("Text", by: nil) == "Text")
	}

	/// A type label grown far past its room is cut at its tail: its first letters match the ungrown label's.
	@Test func anOverlongTypeLabelIsCutAtItsTail() throws {
		let clip = Fixtures.mixed[0]
		let r = try render([AnyView(card(clip, growth: 6)), AnyView(card(clip))])
		// The type label starts after 12 pt padding, the 20 pt icon and 8 pt spacing; compare its first 18 pt.
		#expect(difference(r, x: 40..<58, y: 12..<28) <= 24)
	}

	/// The same for the footer, with the expanded-labels fixture against the original.
	@Test func anOverlongFooterIsCutAtItsTail() throws {
		let original = Fixtures.mixed[0]
		let grown = Fixtures.expandedLabels[0]
		let long = Clip(id: grown.id, kind: grown.kind, text: grown.text, timestamp: grown.timestamp,
			meta: grown.meta + String(repeating: " · more", count: 8))
		let r = try render([AnyView(card(long)), AnyView(card(original))])
		let top = Int(Theme.cardSize.height - Theme.footerHeight)
		#expect(difference(r, x: 12..<40, y: (top + 8)..<(top + 20)) <= 24)
	}

	/// The outermost scale and opacity effects of a view's modifier chain.
	static func outerEffects(_ view: Any) -> (scale: CGSize?, opacity: Double?) {
		var scale: CGSize?, opacity: Double?
		var node: Any? = view
		while let current = node, String(describing: type(of: current)).hasPrefix("ModifiedContent") {
			let mirror = Mirror(reflecting: current)
			if let modifier = mirror.descendant("modifier") {
				let name = String(describing: type(of: modifier)), m = Mirror(reflecting: modifier)
				if name.hasPrefix("_ScaleEffect"), scale == nil { scale = m.descendant("scale") as? CGSize }
				if name.hasPrefix("_OpacityEffect"), opacity == nil { opacity = m.descendant("opacity") as? Double }
			}
			node = mirror.descendant("content")
		}
		return (scale, opacity)
	}

	/// A deleting card fades to nothing and shrinks to the brief's 0.9 (Reduce Motion only fades: `StripMotion` tests).
	@Test func aDeletingCardShrinksAsItFades() throws {
		let clip = Fixtures.mixed[0]
		let r = try render([AnyView(card(clip, removing: true))])
		#expect(stride(from: 3, to: r.pixels.count, by: 4).allSatisfy { r.pixels[$0] < 3 }, "a deleting card still shows")
		let removing = ClipCard(clip: clip, tint: Theme.neutralTint, icon: nil, badge: nil, hovered: false, selected: false,
			removing: true, now: Fixtures.now, highlight: "", thumbnails: ThumbnailCache(), animator: .immediate)
		let effects = Self.outerEffects(removing.body)
		#expect(effects.scale == CGSize(width: StripMotion.deleteScale, height: StripMotion.deleteScale))
		#expect(effects.opacity == 0)
	}
}
