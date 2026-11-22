import Testing
import AppKit
import SwiftUI
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

extension WindowTests {
	/// The brief's extremes: labels longer after translation tail-truncate and never clip. A deleting card shrinks as it fades.
	@MainActor @Suite struct CardLabelTests {}
}

extension WindowTests.CardLabelTests {
	func card(_ clip: Clip, growth: Double? = nil, removing: Bool = false, reduced: Bool = false) -> some View {
		ClipCard(clip: clip, tint: Theme.neutralTint, icon: nil, badge: nil, hovered: false, selected: false, removing: removing,
			age: ClipCard.relative(clip.timestamp, now: Fixtures.now), highlight: "", thumbnails: ThumbnailCache(), animator: .immediate)
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

	/// Real Text accessibility frames, not a duplicated header layout. Yesterday is the longest age label;
	/// with Rich Text it already needs truncation at 1.4×. At 6× both labels must truncate.
	@Test(arguments: [1.0, 2.0]) func grownHeadersStayInsideTheirCardAndTailTruncateWithoutOverlap(displayScale: CGFloat) async throws {
		AccessibilityNode.enableInProcess()
		#expect(Set(Fixtures.mixed.map(\.kind)) == Set(ClipKind.allCases))
		for growth in [1.4, 6.0] {
			for var clip in Fixtures.mixed {
				clip.timestamp = Fixtures.now.addingTimeInterval(-86_400)
				// AX and renderer geometry must use the same layout scale, independent of the attached screen.
				let renderedCard = card(clip, growth: growth).environment(\.displayScale, displayScale)
				let host = NSHostingView(rootView: renderedCard)
				let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -6000, y: -6000), size: Theme.cardSize),
					styleMask: .borderless, backing: .buffered, defer: false)
				window.isReleasedWhenClosed = false
				window.alphaValue = 0
				window.contentView = host
				window.orderFrontRegardless()
				defer { window.orderOut(nil) }
				try? await Task.sleep(for: .milliseconds(50))
				host.layoutSubtreeIfNeeded()
				let type = ClipCard.grown(CardPresentation(clip: clip).typeLabel, by: growth)
				let time = ClipCard.grown("Yesterday", by: growth)
				let nodes = AXNode(host).all
				let typeNode = try #require(nodes.first { $0.value == type })
				let timeNode = try #require(nodes.first { $0.value == time })
				func local(_ frame: CGRect) -> CGRect {
					CGRect(x: frame.minX - window.frame.minX, y: window.frame.maxY - frame.maxY,
						width: frame.width, height: frame.height)
				}
				let typeFrame = local(typeNode.frame), timeFrame = local(timeNode.frame)
				let header = CGRect(x: 40, y: 0, width: Theme.cardSize.width - 40 - 12, height: 40)
				#expect(!typeFrame.isEmpty && !timeFrame.isEmpty)
				#expect(header.contains(typeFrame), "\(type): \(typeFrame)")
				#expect(header.contains(timeFrame), "\(time): \(timeFrame)")
				#expect(typeFrame.minX == header.minX && timeFrame.maxX == header.maxX)
				#expect(typeFrame.maxX + 20 <= timeFrame.minX)
				#expect(typeFrame.height == 16 && timeFrame.height == 14)
				if growth == 6 || clip.kind == .richText {
					let naturalTime = (time as NSString).size(withAttributes:
						[.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]).width
					#expect(timeFrame.width < naturalTime, "the timestamp must actually need truncation")
				}
				if growth == 6 {
					let naturalType = (type as NSString).size(withAttributes:
						[.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
					#expect(typeFrame.width < naturalType, "the type must actually need truncation")
				}

				// Use the actual outer Text frames to draw an independent, explicitly tail-truncated
				// reference. Comparing all label pixels checks the prefix AND the ellipsis, not AX's
				// untruncated string; head/middle truncation or wrapping cannot pass as tail truncation.
				let reference = ZStack(alignment: .topLeading) {
					Theme.card
					Theme.neutralTint.band.frame(height: 40)
					Text(type).font(.system(size: 13, weight: .semibold))
						.foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
						.frame(width: typeFrame.width, alignment: .leading)
						.position(x: typeFrame.midX, y: typeFrame.midY)
					Text(time).font(.system(size: 11, weight: .medium).monospacedDigit())
						.foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
						.frame(width: timeFrame.width, alignment: .leading)
						.position(x: timeFrame.midX, y: timeFrame.midY)
				}
				.frame(width: Theme.cardSize.width, height: Theme.cardSize.height)
				.environment(\.colorScheme, .light)
				let r = try render([AnyView(renderedCard), AnyView(reference.environment(\.displayScale, displayScale))])
				#expect(difference(r, x: 40..<204, y: 1..<39) <= 24, "\(type), \(time)")
			}
		}
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
			removing: true, age: ClipCard.relative(clip.timestamp, now: Fixtures.now), highlight: "", thumbnails: ThumbnailCache(), animator: .immediate)
		let effects = Self.outerEffects(removing.body)
		#expect(effects.scale == CGSize(width: StripMotion.deleteScale, height: StripMotion.deleteScale))
		#expect(effects.opacity == 0)
	}
}
