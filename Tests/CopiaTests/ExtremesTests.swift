import Testing
import AppKit
import SwiftUI
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

extension WindowTests {
	/// The brief's extremes: labels 40% longer after translation (tail-truncate, never clip), and 10,000 items.
	@MainActor @Suite struct ExtremesTests {}
}

extension WindowTests.ExtremesTests {
	/// The footer label's room: the card less 12 pt padding on each side and the 4 pt spacer before the badge.
	static let footerRoom = Theme.cardSize.width - 2 * 12 - 4
	static let footerFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

	func card(_ clip: Clip) -> ClipCard {
		ClipCard(clip: clip, tint: Theme.neutralTint, icon: nil, badge: nil, hovered: false, selected: false, removing: false,
			age: ClipCard.relative(clip.timestamp, now: Fixtures.now), highlight: "", thumbnails: ThumbnailCache(), animator: .immediate)
	}

	/// One card in a real, transparent window far off every screen; its texts as VoiceOver reads them.
	func host(_ clip: Clip) async -> (window: NSWindow, texts: [AccessibilityNode]) {
		AccessibilityNode.enableInProcess()
		let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -6000, y: -6000), size: Theme.cardSize),
			styleMask: .borderless, backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.alphaValue = 0
		window.contentView = NSHostingView(rootView: card(clip))
		window.orderFrontRegardless()
		try? await Task.sleep(for: .milliseconds(60))
		window.contentView?.layoutSubtreeIfNeeded()
		let texts = AccessibilityNode(window.contentView!).all
			.filter { $0.role == NSAccessibility.Role.staticText.rawValue && $0.frame.width > 0 }
		return (window, texts)
	}

	func naturalWidth(_ text: String) -> CGFloat {
		(text as NSString).size(withAttributes: [.font: Self.footerFont]).width
	}

	@Test func expandedLabelsAreFortyPercentLonger() {
		let originals = Fixtures.mixed + Fixtures.extremes
		#expect(Fixtures.expandedLabels.count == originals.count)
		for (expanded, original) in zip(Fixtures.expandedLabels, originals) {
			#expect(Double(expanded.meta.count) >= 1.4 * Double(original.meta.count), "\(expanded.meta)")
			#expect(expanded.meta.hasPrefix(original.meta))
			#expect(expanded.kind == original.kind && expanded.text == original.text)
		}
	}

	/// Every text on a card with 40%-longer labels stays inside the card, and a footer too long for its room is cut
	/// to that room on one line instead of running past the card's edge.
	@Test func expandedLabelsStayInsideTheCardAndTruncate() async throws {
		var truncated = 0
		for clip in Fixtures.expandedLabels {
			let (window, texts) = await host(clip)
			defer { window.orderOut(nil) }
			let bounds = window.frame
			for text in texts {
				#expect(text.frame.minX >= bounds.minX - 0.5 && text.frame.maxX <= bounds.maxX + 0.5,
					"\(clip.meta): “\(text.value.isEmpty ? text.label : text.value)” at \(text.frame) leaves \(bounds)")
			}
			let footer = try #require(texts.first { $0.label == clip.meta || $0.value == clip.meta }, "\(clip.meta)")
			#expect(footer.frame.minY >= bounds.minY - 0.5 && footer.frame.maxY <= bounds.minY + Theme.footerHeight + 0.5,
				"\(clip.meta) footer at \(footer.frame)")
			#expect(footer.frame.width <= Self.footerRoom + 0.5, "\(clip.meta) footer is \(footer.frame.width) pt wide")
			if naturalWidth(clip.meta) > Self.footerRoom + 2 {
				truncated += 1
				#expect(footer.frame.width < naturalWidth(clip.meta) - 1, "\(clip.meta) is not truncated")
			}
		}
		// At 40% longer, "512×512 · PNG · transparent" outgrows its room; the test must see at least that one cut.
		#expect(truncated >= 1)
	}

	/// The strip model over 10,000 items: navigation, selection, ⌘ badges and search.
	@Test func tenThousandItemsNavigateSelectAndSearch() {
		let clips = Fixtures.tenThousand
		let model = StripModel(clips: clips)
		model.open()
		#expect(model.visibleClips.count == 10_000)
		#expect(model.selectedID == clips[0].id)

		model.move(1)
		#expect(model.selectedIndex == 1)
		model.moveToEnd(true)
		#expect(model.selectedID == clips[9_999].id)
		model.move(1)
		#expect(model.selectedIndex == 9_999)
		model.move(-1)
		#expect(model.selectedID == clips[9_998].id)
		model.moveToEnd(false)
		#expect(model.selectedID == clips[0].id)
		model.select(clips[5_000].id)
		#expect(model.selectedIndex == 5_000)

		model.commandHeld = true
		#expect(model.badge(at: 8) == 9)
		#expect(model.badge(at: 9) == nil)
		model.commandHeld = false

		model.query = "History item 9999"
		#expect(model.visibleClips.map(\.id) == [clips[9_998].id])
		#expect(model.selectedID == clips[9_998].id)
		model.query = "item 100"
		#expect(model.visibleClips.map(\.text) == ["History item 100"] + (1_000...1_009).map { "History item \($0)" } + ["History item 10000"])
		model.moveToEnd(true)
		#expect(model.selectedID == clips[9_999].id)
		model.query = "zebra"
		#expect(model.visibleClips.isEmpty)
		#expect(model.selectedID == nil)
		model.query = ""
		#expect(model.visibleClips.count == 10_000)
		#expect(model.selectedID == clips[0].id)
	}
}
