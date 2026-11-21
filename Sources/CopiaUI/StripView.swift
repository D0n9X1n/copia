import AppKit
import SwiftUI
import CopiaCore

/// Forces accessibility display modes for renders; `nil` follows the system.
public struct CopiaOverrides: Sendable, Equatable {
	public var reduceTransparency: Bool?
	public var highContrast: Bool?
	public var reduceMotion: Bool?
	public init(reduceTransparency: Bool? = nil, highContrast: Bool? = nil, reduceMotion: Bool? = nil) {
		self.reduceTransparency = reduceTransparency
		self.highContrast = highContrast
		self.reduceMotion = reduceMotion
	}
}

extension EnvironmentValues {
	@Entry public var copiaOverrides = CopiaOverrides()
}

/// Keeps the search field as first responder while the strip is open.
@MainActor
public final class SearchFocus {
	weak var field: NSTextField?

	public init() {}

	public func focus() {
		guard let field, let window = field.window else { return }
		if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
	}
}

/// The history strip: one glass backdrop, a top bar and a row of solid cards.
public struct StripView: View {
	@Bindable var model: StripModel
	let focus: SearchFocus
	let thumbnails: ThumbnailCache
	let now: () -> Date
	let sources: SourceAppearance

	@Namespace private var lensSpace
	@State private var position = ScrollPosition(edge: .leading)
	@State private var scrollX: CGFloat = 0
	@State private var viewport: CGFloat = 0
	/// Cards deleted while the strip is open, so an undo brings them back with the reverse of the delete.
	@State private var departed: Set<UUID> = []
	@Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
	@Environment(\.accessibilityReduceMotion) private var systemReduceMotion
	@Environment(\.colorSchemeContrast) private var systemContrast
	@Environment(\.copiaOverrides) private var overrides
	private var reduceTransparency: Bool { overrides.reduceTransparency ?? systemReduceTransparency }
	private var reduceMotion: Bool { overrides.reduceMotion ?? systemReduceMotion }
	private var highContrast: Bool { overrides.highContrast ?? (systemContrast == .increased) }

	public init(model: StripModel, focus: SearchFocus, thumbnails: ThumbnailCache,
		now: @escaping () -> Date = Date.init, sources: SourceAppearance = .shared) {
		self.model = model
		self.focus = focus
		self.thumbnails = thumbnails
		self.now = now
		self.sources = sources
	}

	public var body: some View {
		let _ = Diagnostics.body()
		VStack(spacing: 0) {
			Spacer(minLength: 0)
			StripSlide(model: model, reduced: reduceMotion) { strip.frame(height: Theme.panelHeight) }
		}
	}

	/// Opening slides up without a fade (Reduce Motion fades in place). Closing slides down and fades out together,
	/// on the close curve: `isClosing` is set before the animated change, so the fade starts from full opacity.
	static func stripOpacity(appeared: Bool, closing: Bool, reduced: Bool) -> Double {
		if closing { return appeared ? 1 : 0 }
		return StripMotion.openOpacity(appeared: appeared, reduced: reduced)
	}

	@ViewBuilder private var strip: some View {
		let shape = RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
		VStack(spacing: 0) {
			topBar.frame(height: Theme.topBarHeight)
			if model.cardsMounted { content.frame(height: Theme.rowHeight) } else { Color.clear.frame(height: Theme.rowHeight) }
			Spacer(minLength: Theme.bottomPadding)
		}
		.frame(maxWidth: .infinity)
		.background {
			if reduceTransparency {
				shape.fill(Theme.solidBackdrop)
			} else {
				// Clipped: the glass casts its own shadow below the shape, and the window's square bottom edge cut it into corners.
				// The dark-mode scrim bounds how light the glass gets over a bright wallpaper, so text on it keeps 4.5:1.
				Color.clear.glassEffect(.regular, in: shape).clipShape(shape)
					.overlay { shape.fill(Theme.glassScrim) }
			}
		}
		.overlay {
			shape.strokeBorder(Color.white.opacity(highContrast ? 0.35 : 0.14), lineWidth: 0.5)
		}
		.overlay(alignment: .bottom) { toast.padding(.bottom, 22) }
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Clipboard history, \(model.clips.count) items")
	}

	// MARK: Top bar

	private var topBar: some View {
		HStack(spacing: 12) {
			SearchPill(model: model, focus: focus)
			Spacer()
			if model.paused {
				Label("Capture paused", systemImage: "pause.fill")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(Theme.ink)
					.padding(.horizontal, 10).frame(height: 24)
					.background(Theme.field, in: .capsule)
			}
			Text(model.query.isEmpty ? "\(model.clips.count) items" : "\(model.visibleClips.count) of \(model.clips.count)")
				.font(.system(size: 11, weight: .medium).monospacedDigit())
				.foregroundStyle(Theme.glassInk2(highContrast: highContrast))
		}
		.padding(.leading, 16)
		.padding(.trailing, 20)
		.padding(.top, 6)
	}

	// MARK: Row

	@ViewBuilder private var content: some View {
		let visible = model.visibleClips
		let rows = visible.enumerated().map { slot, clip in
			(key: StripMotion.cardKey(id: clip.id, slot: slot, reduced: reduceMotion), slot: slot, clip: clip)
		}
		if model.clips.isEmpty {
			emptyState(symbol: "list.clipboard", title: "Nothing copied yet",
				detail: "Copy anything with ⌘C and it appears here.")
		} else if visible.isEmpty {
			emptyState(symbol: "magnifyingglass", title: "No matches for “\(model.query)”", detail: "⎋ clears search")
		} else {
			ScrollView(.horizontal) {
				LazyHStack(spacing: Theme.cardGap) {
					ForEach(rows, id: \.key) { row in
						card(row.clip, index: row.slot)
							.transition(transition(for: row.clip.id))
					}
				}
				.padding(.horizontal, Theme.rowPadding)
				.frame(height: Theme.rowHeight)
			}
			.scrollIndicators(.never)
			.scrollPosition($position)
			.scrollEdgeEffectStyle(.soft, for: .horizontal)
			.onScrollGeometryChange(for: CGSize.self) { geo in
				CGSize(width: geo.contentOffset.x, height: geo.containerSize.width)
			} action: { _, new in
				scrollX = new.width
				viewport = new.height
			}
			// The index, not the ID: a new copy at the front moves the selection without changing it.
			.onChange(of: visible.firstIndex { $0.id == model.selectedID }) { _, _ in scrollToSelection(animated: true) }
			.onChange(of: model.removingIDs) { _, removing in departed.formUnion(removing) }
			.onChange(of: model.cardsMounted) { _, mounted in if !mounted { departed.removeAll() } }
			.onAppear { scrollToSelection(animated: false) }
		}
	}

	/// How a card enters and leaves. A card deleted this session comes back (undo) with the reverse of its delete.
	private func transition(for id: UUID) -> AnyTransition {
		switch StripMotion.cardTransition(returning: departed.contains(id), reduced: reduceMotion) {
		case .crossfade: .opacity
		case .slideIn: .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity)
		case .reverseDelete: .scale(scale: StripMotion.deleteScale).combined(with: .opacity)
		}
	}

	private func card(_ clip: Clip, index: Int) -> some View {
		let selected = clip.id == model.selectedID
		let tint = clip.sourceBundleID == nil ? Theme.neutralTint : sources.tint(for: clip.sourceBundleID)
		return ClipCard(clip: clip, tint: tint, icon: sources.icon(for: clip.sourceBundleID),
			badge: model.badge(for: clip.id), hovered: model.hoveredID == clip.id, selected: selected,
			removing: model.removingIDs.contains(clip.id), now: now(), highlight: model.query, thumbnails: thumbnails,
			animator: model.animator)
			.background {
				if selected {
					LensRing(removing: model.removingIDs.contains(clip.id)).matchedGeometryEffect(id: "lens", in: lensSpace)
				}
			}
			.focusEffectDisabled()
			.onHover { inside in
				if inside { model.hoveredID = clip.id } else if model.hoveredID == clip.id { model.hoveredID = nil }
			}
			.onTapGesture(count: 2) { Task { await model.perform(.paste, id: clip.id) } }
			.onTapGesture { model.select(clip.id); focus.focus() }
			.contextMenu {
				ForEach(CardAction.allCases, id: \.self) { action in
					Button(action.rawValue, role: action == .delete ? .destructive : nil) {
						Task { await model.perform(action, id: clip.id) }
					}
				}
			}
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(CardAccessibility(clip: clip, now: now()).label)
			.accessibilityAddTraits(selected ? .isSelected : [])
			.accessibilityActions {
				ForEach(CardAction.allCases, id: \.self) { action in
					Button(action.rawValue) { Task { await model.perform(action, id: clip.id) } }
				}
			}
	}

	private func scrollToSelection(animated: Bool) {
		guard let index = model.selectedIndex, viewport > 0 else { return }
		let target = PanelLayout.offset(selectedMinX: PanelLayout.cardMinX(index: index), viewport: viewport,
			current: scrollX, contentWidth: PanelLayout.contentWidth(count: model.visibleClips.count))
		guard abs(target - scrollX) > 0.5 else { return }
		if animated, !reduceMotion {
			// Through the Animator, so the curve comes from the Motion table and tests see it.
			model.animator.run(.lens, { position.scrollTo(x: target) }, {})
		} else {
			position.scrollTo(x: target)
		}
	}

	private func emptyState(symbol: String, title: String, detail: String) -> some View {
		VStack(spacing: 10) {
			Image(systemName: symbol).font(.system(size: 40, weight: .regular)).foregroundStyle(Theme.ink.opacity(0.55))
			Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
				.lineLimit(1).truncationMode(.tail)
			Text(detail).font(.system(size: 13)).foregroundStyle(Theme.glassInk2(highContrast: highContrast))
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding(.bottom, 12)
	}

	// MARK: Toast

	@ViewBuilder private var toast: some View {
		if let toast = model.toast {
			HStack(spacing: 12) {
				Image(systemName: toast == .accessibilityRequired ? "hand.raised.fill" : (toast == .deleted ? "trash" : "exclamationmark.triangle.fill"))
					.foregroundStyle(Theme.ink)
				Text(toast.message).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
				if toast == .accessibilityRequired {
					Button("Open Settings") { model.openAccessibilitySettings() }
						.buttonStyle(.borderedProminent).controlSize(.small)
				} else if toast == .deleted {
					Button("Undo") { Task { await model.undo() } }.buttonStyle(.bordered).controlSize(.small)
				}
			}
			.padding(.horizontal, 16).frame(height: 40)
			.background(Theme.card, in: .capsule)
			.overlay { Capsule().strokeBorder(Theme.stroke(hovered: false, highContrast: highContrast)) }
			.shadow(color: .black.opacity(0.2), radius: 12, y: 4)
			.transition(.move(edge: .bottom).combined(with: .opacity))
		}
	}
}

/// Moves and fades the strip for open and close. It alone reads the open state, so the slide does not rebuild the
/// strip or its cards on the first frames after ⌘Y.
private struct StripSlide<Content: View>: View {
	let model: StripModel
	let reduced: Bool
	@ViewBuilder let content: Content

	var body: some View {
		content
			.offset(y: StripMotion.openOffset(appeared: model.appeared, reduced: reduced))
			.opacity(StripView.stripOpacity(appeared: model.appeared, closing: model.isClosing, reduced: reduced))
	}
}

/// The selection lens (brief): a 3 pt accent stroke over a 12% accent fill, radius 21, 5 pt outside the card, behind it.
/// A halo edges the stroke outside so it stays visible on any glass. It fades with a deleting card, so the fill never
/// shows as a block where the card was.
struct LensRing: View {
	var removing = false
	static let fillOpacity = 0.12

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: Theme.lensRadius, style: .continuous)
				.fill(Color.accentColor.opacity(Self.fillOpacity))
				.padding(Theme.lensHaloWidth)
			RoundedRectangle(cornerRadius: Theme.lensRadius + Theme.lensHaloWidth, style: .continuous)
				.strokeBorder(Theme.lensHalo, lineWidth: Theme.lensHaloWidth)
			RoundedRectangle(cornerRadius: Theme.lensRadius, style: .continuous)
				.strokeBorder(Color.accentColor, lineWidth: 3)
				.padding(Theme.lensHaloWidth)
		}
		.padding(-(Theme.lensOutset + Theme.lensHaloWidth))
		.opacity(removing ? 0 : 1)
	}
}

/// The search capsule: 32 pt tall, 240 wide, 360 with a query.
struct SearchPill: View {
	@Bindable var model: StripModel
	let focus: SearchFocus

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink.opacity(0.6))
			SearchField(model: model, focus: focus)
		}
		.padding(.horizontal, 10)
		.frame(width: model.query.isEmpty ? 240 : 360, height: 32)
		.background(Theme.field, in: .capsule)
	}
}

/// A native text field so typing, input methods and the field editor all behave normally.
/// Strip commands are read from the field editor's commands, which never fire mid-composition.
struct SearchField: NSViewRepresentable {
	@Bindable var model: StripModel
	let focus: SearchFocus

	func makeCoordinator() -> Coordinator { Coordinator(model: model) }

	func makeNSView(context: Context) -> NSTextField {
		let field = NSTextField()
		field.isBordered = false
		field.drawsBackground = false
		field.focusRingType = .none
		field.font = .systemFont(ofSize: 15)
		// Glass metadata ink: the system placeholder color falls below 4.5:1 on the glass.
		field.placeholderAttributedString = NSAttributedString(string: "Type to search",
			attributes: [.foregroundColor: Theme.glassInk2NS, .font: NSFont.systemFont(ofSize: 15)])
		field.delegate = context.coordinator
		field.cell?.isScrollable = true
		field.cell?.wraps = false
		field.setAccessibilityLabel("Search clipboard history")
		focus.field = field
		return field
	}

	func updateNSView(_ field: NSTextField, context: Context) {
		context.coordinator.model = model
		if field.stringValue != model.query { field.stringValue = model.query }
	}

	@MainActor
	final class Coordinator: NSObject, NSTextFieldDelegate {
		var model: StripModel
		init(model: StripModel) { self.model = model }

		func controlTextDidChange(_ note: Notification) {
			guard let field = note.object as? NSTextField else { return }
			model.query = field.stringValue
		}

		func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
			let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
			switch selector {
			case #selector(NSResponder.moveLeft(_:)): model.move(-1)
			case #selector(NSResponder.moveRight(_:)): model.move(1)
			case #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToLeftEndOfLine(_:)):
				model.moveToEnd(false)
			case #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)):
				model.moveToEnd(true)
			case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
				Task { await model.paste(plain: shift) }
			case #selector(NSResponder.cancelOperation(_:)): model.escape()
			case #selector(NSResponder.deleteBackward(_:)):
				guard model.query.isEmpty else { return false }
				Task { await model.backspace() }
			default: return false
			}
			return true
		}
	}
}

/// What VoiceOver reads for a card.
struct CardAccessibility {
	let clip: Clip
	let now: Date

	var preview: String { String(clip.text.prefix(120)) }
	var actions: [String] { CardAction.allCases.map(\.rawValue) }

	var label: String {
		let kind = CardPresentation(clip: clip).typeLabel
		let source = clip.sourceName ?? "Unknown app"
		let spoken = switch ClipCard.relative(clip.timestamp, now: now) {
		case "Now": "just now"
		case "Yesterday": "yesterday"
		case let age: age + " ago"
		}
		return "\(kind) from \(source), \(spoken): \(preview)"
	}
}
