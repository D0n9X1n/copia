import AppKit
import SwiftUI
import CopiaCore

@MainActor
final class HistoryRowPosition {
	weak var scroll: NSScrollView?

	/// Shows the scroll bar briefly, once laid out, when the cards overflow.
	func flash() {
		DispatchQueue.main.async { [weak self] in (self?.scroll as? HistoryScrollBase)?.flashIfOverflowing() }
	}
}

/// The history row's scrolling: a plain mouse wheel moves it sideways, and a native scroll bar sits in the band below
/// the cards. Everything else (trackpad, Magic Mouse, Shift+wheel, tilt) scrolls as AppKit does.
@MainActor
class HistoryScrollBase: NSScrollView {
	/// Copia's own flashes of the scroll bar, for tests.
	private(set) var flashCount = 0

	override init(frame: NSRect) {
		super.init(frame: frame)
		drawsBackground = false
		hasHorizontalScroller = true
		hasVerticalScroller = false
		autohidesScrollers = true
		verticalScrollElasticity = .none
		horizontalScroller?.controlSize = .small
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	/// The override only peeks at each event; gesture streams keep AppKit's responsive scrolling.
	override class var isCompatibleWithResponsiveScrolling: Bool { true }

	/// Cards keep the top 248 pt; the scroll bar sits in the band below them, lined up with the first card.
	override func tile() {
		super.tile()
		let band = Theme.scrollBand, rows = max(0, bounds.height - band)
		// The band is at the bottom of the view; a scroll view is flipped, so that's its larger y.
		let bandMinY = isFlipped ? rows : 0
		contentView.frame = CGRect(x: 0, y: isFlipped ? 0 : band, width: bounds.width, height: rows)
		guard let scroller = horizontalScroller else { return }
		let height = min(band, NSScroller.scrollerWidth(for: scroller.controlSize, scrollerStyle: scrollerStyle))
		scroller.frame = CGRect(x: Theme.rowPadding, y: bandMinY + ((band - height) / 2).rounded(.down),
			width: max(0, bounds.width - 2 * Theme.rowPadding), height: height)
	}

	/// A mouse wheel turned up or down moves the row as it would move a page, so natural scrolling still applies; a
	/// notched line moves a quarter card, a precise delta moves 1:1.
	override func scrollWheel(with event: NSEvent) {
		guard let sideways = Self.sideways(event) else { return super.scrollWheel(with: event) }
		guard !event.hasPreciseScrollingDeltas else { return super.scrollWheel(with: sideways) }
		// Only this wheel gets the larger step; Shift+wheel and tilt keep AppKit's line.
		let line = horizontalLineScroll
		horizontalLineScroll = Theme.wheelStep
		defer { horizontalLineScroll = line }
		super.scrollWheel(with: sideways)
	}

	/// A mouse wheel turned up or down (no gesture phase, no Shift, mostly vertical) as the same event turned sideways;
	/// nil for everything AppKit scrolls as it is: trackpad and Magic Mouse gestures, momentum, Shift+wheel, tilt.
	static func sideways(_ event: NSEvent) -> NSEvent? {
		guard event.type == .scrollWheel, event.phase.isEmpty, event.momentumPhase.isEmpty,
			!event.modifierFlags.contains(.shift), abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
			let source = event.cgEvent?.copy() else { return nil }
		// Read every vertical delta first: setting the line delta recomputes the others on that axis.
		let lines = source.getIntegerValueField(.scrollWheelEventDeltaAxis1)
		let points = source.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
		let fixed = source.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
		source.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lines)
		source.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
		source.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed)
		source.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
		source.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: points)
		source.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
		return NSEvent(cgEvent: source)
	}

	/// Flashes the overlay scroll bar when the cards overflow; a legacy bar is always shown.
	func flashIfOverflowing() {
		guard let document = documentView, document.frame.width > contentView.bounds.width + 0.5 else { return }
		flashCount += 1
		flashScrollers()
	}
}

@MainActor @Observable private final class MountedSlots {
	var range = 0..<0
}

private struct MountedCards<Card: View>: View {
	let model: StripModel
	let slots: MountedSlots
	let reduced: Bool
	let card: (Clip, Int) -> Card

	var body: some View {
		let clips = model.visibleClips
		let rows = slots.range.clamped(to: clips.indices).map { slot in
			(key: StripMotion.cardKey(id: clips[slot].id, slot: slot, reduced: reduced), slot: slot, clip: clips[slot])
		}
		HStack(spacing: Theme.cardGap) {
			ForEach(rows, id: \.key) { row in card(row.clip, row.slot) }
		}.frame(width: PanelLayout.contentWidth(count: rows.count) - 2 * Theme.rowPadding, height: Theme.rowHeight, alignment: .leading)
	}
}

private final class HistoryDocument: NSView {
	let host = NSHostingView(rootView: AnyView(EmptyView()))

	var backedRect: NSRect {
		guard !host.frame.isEmpty, !bounds.isEmpty else { return .zero }
		let left = host.frame.minX == Theme.rowPadding ? bounds.minX : host.frame.minX
		let right = host.frame.maxX >= bounds.maxX - Theme.rowPadding ? bounds.maxX : host.frame.maxX
		return NSRect(x: left, y: bounds.minY, width: max(0, right - left), height: bounds.height).intersection(bounds)
	}

	override func prepareContent(in rect: NSRect) {
		// Only mounted cards and the empty end margins are ready for AppKit's scroll overdraw.
		let backed = backedRect
		let viewport = enclosingScrollView?.documentVisibleRect ?? visibleRect
		let area = rect.intersection(backed).union(viewport.intersection(backed))
		super.prepareContent(in: area.isNull ? .zero : area)
	}
}

struct HistoryRow<Card: View>: NSViewRepresentable {
	let clips: [Clip]
	let position: HistoryRowPosition
	let overrides: CopiaOverrides
	let reduced: Bool
	let model: StripModel
	let card: (Clip, Int) -> Card

	func makeNSView(context: Context) -> HistoryScrollView<Card> {
		let view = HistoryScrollView<Card>()
		position.scroll = view
		return view
	}

	func updateNSView(_ view: HistoryScrollView<Card>, context: Context) {
		view.update(clips: clips, reduced: reduced, overrides: overrides, model: model, card: card)
	}
}

@MainActor
final class HistoryScrollView<Card: View>: HistoryScrollBase {
	private let document = HistoryDocument()
	private var host: NSHostingView<AnyView> { document.host }
	private var clips: [Clip] = []
	private weak var model: StripModel?
	private var reduced = false
	private var overrides = CopiaOverrides()
	private let slots = MountedSlots()

	override init(frame: NSRect) {
		super.init(frame: frame)
		document.wantsLayer = true
		documentView = document
		host.sizingOptions = []
		document.addSubview(host)
		contentView.postsBoundsChangedNotifications = true
		NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func update(clips: [Clip], reduced: Bool, overrides: CopiaOverrides, model: StripModel, card: @escaping (Clip, Int) -> Card) {
		self.clips = clips
		if self.model !== model || self.reduced != reduced || self.overrides != overrides {
			self.model = model
			self.reduced = reduced
			self.overrides = overrides
			// Keep the root observing model transactions; replacing it on every update makes deletions jump.
			host.rootView = AnyView(MountedCards(model: model, slots: slots, reduced: reduced, card: card))
		}
		let size = CGSize(width: PanelLayout.contentWidth(count: clips.count), height: Theme.rowHeight)
		if document.frame.size != size {
			document.setFrameSize(size)
			refresh()
			document.preparedContentRect = document.backedRect
		} else {
			refresh()
		}
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		(window as? StripPanel)?.openContextMenu = { [weak self] event in self?.showContextMenu(for: event) ?? false }
	}

	private func showContextMenu(for event: NSEvent) -> Bool {
		let point = document.convert(event.locationInWindow, from: nil)
		let x = point.x - Theme.rowPadding, stride = Theme.cardSize.width + Theme.cardGap
		let index = Int(floor(x / stride)), y = (Theme.rowHeight - Theme.cardSize.height) / 2
		guard clips.indices.contains(index), x - CGFloat(index) * stride < Theme.cardSize.width,
			y..<(y + Theme.cardSize.height) ~= point.y, let model, model.cardsMounted else { return false }
		let clip = clips[index], menu = NSMenu()
		for action in CardAction.allCases {
			let item = NSMenuItem(title: action.label(for: clip), action: #selector(choose(_:)), keyEquivalent: "")
			item.target = self
			let choose: () -> Void = { [weak model] in
				guard let model else { return }
				model.request { await model.perform(action, id: clip.id) }
			}
			item.representedObject = choose
			menu.addItem(item)
		}
		NSMenu.popUpContextMenu(menu, with: event, for: self)
		return true
	}

	@objc private func choose(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }

	override func layout() { super.layout(); refresh() }
	@objc private func scrolled() { refresh() }

	private func refresh() {
		let bounds = contentView.bounds
		let visible = PanelLayout.visibleSlots(offset: bounds.minX, viewport: bounds.width, count: clips.count)
		let current = slots.range
		guard current.lowerBound > visible.lowerBound || current.upperBound < visible.upperBound || current.upperBound > clips.count else { return }
		// One neighbour slides into view; the next keeps its entrance animation beyond the viewport.
		let initial = visible.lowerBound..<min(clips.count, visible.upperBound + 2)
		let mounted = current.isEmpty ? initial : PanelLayout.mountedSlots(around: visible, count: clips.count)
		slots.range = mounted
		let width = PanelLayout.contentWidth(count: mounted.count) - 2 * Theme.rowPadding
		host.frame = CGRect(x: PanelLayout.cardMinX(index: mounted.lowerBound), y: 0, width: width, height: Theme.rowHeight)
		document.preparedContentRect = document.backedRect
	}
}
