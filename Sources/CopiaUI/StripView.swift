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
		VStack(spacing: 0) {
			Spacer(minLength: 0)
			strip
				.frame(height: Theme.panelHeight)
				.offset(y: model.appeared ? 0 : (reduceMotion ? 0 : 56))
				.opacity(model.appeared ? 1 : 0)
				.scaleEffect(model.appeared || reduceMotion ? 1 : 0.985, anchor: .bottom)
		}
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
				Color.clear.glassEffect(.regular, in: shape).clipShape(shape)
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
				.foregroundStyle(Theme.ink2(highContrast: highContrast))
		}
		.padding(.leading, 16)
		.padding(.trailing, 20)
		.padding(.top, 6)
	}

	// MARK: Row

	@ViewBuilder private var content: some View {
		let visible = model.visibleClips
		if model.clips.isEmpty {
			emptyState(symbol: "list.clipboard", title: "Nothing copied yet",
				detail: "Copy anything with ⌘C and it appears here.")
		} else if visible.isEmpty {
			emptyState(symbol: "magnifyingglass", title: "No matches for “\(model.query)”", detail: "⎋ clears search")
		} else {
			ScrollView(.horizontal) {
				LazyHStack(spacing: Theme.cardGap) {
					ForEach(Array(visible.enumerated()), id: \.element.id) { index, clip in
						card(clip, index: index)
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
				scrollX = new.width == 0 ? scrollX : new.width
				scrollX = new.width
				viewport = new.height
			}
			.onChange(of: model.selectedID) { _, _ in scrollToSelection(animated: true) }
			.onAppear { scrollToSelection(animated: false) }
		}
	}

	private func card(_ clip: Clip, index: Int) -> some View {
		let selected = clip.id == model.selectedID
		let tint = clip.sourceBundleID == nil ? Theme.neutralTint : sources.tint(for: clip.sourceBundleID)
		return ClipCard(clip: clip, tint: tint, icon: sources.icon(for: clip.sourceBundleID),
			badge: model.badge(for: clip.id), hovered: model.hoveredID == clip.id, selected: selected,
			removing: model.removingIDs.contains(clip.id), now: now(), highlight: model.query, thumbnails: thumbnails)
			.background {
				if selected {
					RoundedRectangle(cornerRadius: Theme.lensRadius, style: .continuous)
						.fill(Color.accentColor.opacity(0.12))
						.strokeBorder(Color.accentColor, lineWidth: 3)
						.padding(-Theme.lensOutset)
						.matchedGeometryEffect(id: "lens", in: lensSpace)
				}
			}
			.id(clip.id)
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
		if animated, !reduceMotion, let animation = Motion.value(.lens, reduced: false).animation {
			withAnimation(animation) { position.scrollTo(x: target) }
		} else {
			position.scrollTo(x: target)
		}
	}

	private func emptyState(symbol: String, title: String, detail: String) -> some View {
		VStack(spacing: 10) {
			Image(systemName: symbol).font(.system(size: 40, weight: .regular)).foregroundStyle(Theme.ink.opacity(0.55))
			Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
				.lineLimit(1).truncationMode(.tail)
			Text(detail).font(.system(size: 13)).foregroundStyle(Theme.ink2(highContrast: highContrast))
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
		field.placeholderString = "Type to search"
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
		let age = ClipCard.relative(clip.timestamp, now: now)
		return "\(kind) from \(source), \(age == "Now" ? "just now" : age + " ago"): \(preview)"
	}
}
