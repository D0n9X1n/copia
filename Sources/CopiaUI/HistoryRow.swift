import AppKit
import SwiftUI
import CopiaCore

@MainActor
final class HistoryRowPosition {
	weak var scroll: NSScrollView?
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
final class HistoryScrollView<Card: View>: NSScrollView {
	private let document = NSView()
	private let host = NSHostingView(rootView: AnyView(EmptyView()))
	private var clips: [Clip] = []
	private weak var model: StripModel?
	private var reduced = false
	private var overrides = CopiaOverrides()
	private let slots = MountedSlots()

	override init(frame: NSRect) {
		super.init(frame: frame)
		drawsBackground = false
		hasHorizontalScroller = false
		hasVerticalScroller = false
		verticalScrollElasticity = .none
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
		if document.frame.size != size { document.setFrameSize(size) }
		refresh()
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
	}
}
