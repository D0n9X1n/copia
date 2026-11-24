import AppKit
import SwiftUI
import CopiaCore

/// Forces accessibility display modes for renders; `nil` follows the system.
public struct CopiaOverrides: Sendable, Equatable {
	public var reduceTransparency: Bool?
	public var highContrast: Bool?
	public var reduceMotion: Bool?
	/// Lengthens the card's header labels by this factor, standing in for a longer translation (the brief's 40% check).
	public var labelGrowth: Double?
	public init(reduceTransparency: Bool? = nil, highContrast: Bool? = nil, reduceMotion: Bool? = nil, labelGrowth: Double? = nil) {
		self.reduceTransparency = reduceTransparency
		self.highContrast = highContrast
		self.reduceMotion = reduceMotion
		self.labelGrowth = labelGrowth
	}
}

extension EnvironmentValues {
	@Entry public var copiaOverrides = CopiaOverrides()
}

/// The history strip: one glass backdrop, a top bar and a row of solid cards.
public struct StripView: View {
	@Bindable var model: StripModel
	let focus: SearchFocus
	let thumbnails: ThumbnailCache
	let now: () -> Date
	let sources: SourceAppearance

	@Namespace private var lensSpace
	@State private var row = HistoryRowPosition()
	/// Cards deleted while the strip is open, so an undo brings them back with the reverse of the delete.
	@State private var departed: Set<UUID> = []
	/// What the current press is for, decided when it starts. Not observed, so a press never re-renders the strip.
	@State private var press = PressLatch()
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
		// Copia ships one left-to-right localization. Pinning the strip's own layout keeps the footer pin, its hit area and
		// newest-first order fixed; card text still follows its own direction (CardPresentation.textDirection).
		.environment(\.layoutDirection, .leftToRight)
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
			// The card row takes the bottom padding as the band its scroll bar sits in; the cards don't move.
			let showsRow = model.cardsMounted && !model.visibleClips.isEmpty
			if model.cardsMounted {
				content.frame(height: Theme.rowHeight + (showsRow ? Theme.scrollBand : 0))
			} else {
				Color.clear.frame(height: Theme.rowHeight)
			}
			Spacer(minLength: showsRow ? 0 : Theme.bottomPadding)
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
			if model.storageStatus != .ready {
				Text(model.storageStatus.message).font(.system(size: 12, weight: .medium))
					.foregroundStyle(Theme.ink).lineLimit(2)
					.padding(.horizontal, 10).padding(.vertical, 4)
					.background(Theme.card, in: .capsule)
					.accessibilityLabel(model.storageStatus.message)
			}
			if let hint = model.restoreHint {
				RestoreHintView(hint: hint, highContrast: highContrast, copied: model.clipboard?.id, reduceMotion: reduceMotion)
					.fixedSize()
					.transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
			}
			Spacer(minLength: 12)
			if model.paused {
				Label("Capture paused", systemImage: "pause.fill")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(Theme.ink)
					.padding(.horizontal, 10).frame(height: 24)
					.background(Theme.field, in: .capsule)
			}
			Text(countLabel)
				.font(.system(size: 11, weight: .medium).monospacedDigit())
				.foregroundStyle(Theme.glassInk2(highContrast: highContrast))
				.lineLimit(1).fixedSize()
			Button { model.actions.openSettings() } label: { Image(systemName: "gearshape") }
				.buttonStyle(.plain).accessibilityLabel("Settings").help("Open Settings")
		}
		// Search lines up with the first card.
		.padding(.leading, Theme.rowPadding)
		.padding(.trailing, 20)
		.padding(.top, 6)
		.animation(reduceMotion ? .linear(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.78), value: model.restoreHint)
	}

	private var countLabel: String {
		if let count = model.groupCount { return "\(count) selected" }
		return model.query.isEmpty ? "\(model.clips.count) items" : "\(model.visibleClips.count) of \(model.clips.count)"
	}

	// MARK: Row

	@ViewBuilder private var content: some View {
		let visible = model.visibleClips

		if model.clips.isEmpty {
			emptyState(symbol: "list.clipboard", title: "Nothing copied yet",
				detail: "Copy anything with ⌘C and it appears here.")
		} else if visible.isEmpty {
			emptyState(symbol: "magnifyingglass", title: "No matches for “\(model.query)”", key: ("esc", "Escape"), detail: "clears search")
		} else {
			HistoryRow(clips: visible, position: row, overrides: overrides, reduced: reduceMotion, model: model) { clip, index in
				card(clip, index: index).transition(transition(for: clip.id))
					.environment(\.copiaOverrides, overrides)
			}
			.scrollEdgeEffectStyle(.soft, for: .horizontal)
			// The index, not the ID: a new copy at the front moves the selection without changing it.
			.onChange(of: visible.firstIndex { $0.id == model.selectedID }) { _, _ in scrollToSelection(animated: true) }
			.onChange(of: model.removingIDs) { _, removing in departed.formUnion(removing) }
			.onChange(of: model.cardsMounted) { _, mounted in if !mounted { departed.removeAll() } }
			.onAppear {
				scrollToSelection(animated: false)
				// The scroll bar shows briefly once the open settles, without rebuilding the strip.
				model.onOpenSettled = { [row] in row.flash() }
				if model.isOpenSettled { row.flash() }
			}
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
		let primary = clip.id == model.selectedID
		let selected = model.isSelected(clip.id)
		let tint = clip.sourceBundleID == nil ? Theme.neutralTint : sources.tint(for: clip.sourceBundleID)
		let timestamp = now()
		let showsPin = clip.isPinned || primary || model.hoveredID == clip.id
		/// Whether this card owns the current press: it started on the card, not on a pin that was visible at that moment.
		func cardOwnsPress(_ start: CGPoint) -> Bool {
			guard let panel = focus.field?.window as? StripPanel else { return false }
			if press.number != panel.pressNumber || press.card != clip.id {
				press.number = panel.pressNumber
				press.card = clip.id
				press.onPin = showsPin && ClipCard.pinSlot.contains(start)
			}
			return !press.onPin
		}
		return ClipCard(clip: clip, tint: tint, icon: sources.icon(for: clip.sourceBundleID),
			badge: model.badge(at: index), hovered: model.hoveredID == clip.id, selected: selected,
			removing: model.removingIDs.contains(clip.id), age: ClipCard.relative(clip.timestamp, now: timestamp), highlight: model.query, thumbnails: thumbnails,
			animator: model.animator, showsPin: showsPin, pinControl: true)
			.background {
				if primary {
					LensRing(removing: model.removingIDs.contains(clip.id))
						.matchedGeometryEffect(id: "lens", in: lensSpace)
						.allowsHitTesting(false)
				}
			}
			.overlay {
				if selected && !primary {
					RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
				}
			}
			.contentShape(.interaction, Rectangle())
			.focusEffectDisabled()
			.onHover { inside in
				if inside { model.hoveredID = clip.id } else if model.hoveredID == clip.id { model.hoveredID = nil }
			}
			.simultaneousGesture(DragGesture(minimumDistance: 0)
				.onChanged { value in
					guard (focus.field?.window as? StripPanel)?.handlingContextClick != true, cardOwnsPress(value.startLocation) else { return }
					model.selectOnPress(clip.id); focus.focus()
				}
				.onEnded { value in
					// A click copies on release; a drag (the panel tracks the whole press) or a release away from the card does not.
					guard let panel = focus.field?.window as? StripPanel, let count = panel.primaryClickCount else { return }
					guard cardOwnsPress(value.startLocation) else {
						// A click that starts and ends on the visible pin toggles it, without copying or selecting.
						if ClipCard.pinSlot.contains(value.location) { model.request { await model.togglePin(clip.id) } }
						return
					}
					guard CGRect(origin: .zero, size: Theme.cardSize).contains(value.location) else { return }
					// It is a double-click only if the press before it was a click on this same card, not on a pin or another card.
					let double = count >= 2 && press.lastClick.map { $0.0 == panel.pressNumber &- 1 && $0.1 == clip.id } == true
					press.lastClick = (panel.pressNumber, clip.id)
					model.request { await model.click(clip.id, count: double ? 2 : 1) }
				})
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(CardAccessibility(clip: clip, now: timestamp).label)
			.accessibilityValue(model.clipboard?.id == clip.id ? "On clipboard" : "")
			.accessibilityAddTraits(selected ? .isSelected : [])
			.accessibilityActions {
				ForEach(CardAction.allCases, id: \.self) { action in
					Button(action.label(for: clip)) { model.request { await model.perform(action, id: clip.id) } }
				}
			}
	}

	private func scrollToSelection(animated: Bool) {
		guard let scroll = row.scroll, let index = model.selectedIndex else { return }
		let clip = scroll.contentView, current = clip.bounds.minX
		let target = PanelLayout.offset(selectedMinX: PanelLayout.cardMinX(index: index), viewport: clip.bounds.width,
			current: current, contentWidth: PanelLayout.contentWidth(count: model.visibleClips.count))
		guard abs(target - current) > 0.5 else { return }
		let point = CGPoint(x: target, y: clip.bounds.minY)
		if animated, let animation = Motion.value(.lens, reduced: reduceMotion).animation {
			NSAnimationContext.animate(animation) { clip.animator().setBoundsOrigin(point) }
		} else {
			clip.scroll(to: point)
			scroll.reflectScrolledClipView(clip)
		}
	}

	/// `key`, when set, is drawn as a keycap before `detail` and spoken by name.
	private func emptyState(symbol: String, title: String, key: (shown: String, spoken: String)? = nil, detail: String) -> some View {
		VStack(spacing: 10) {
			Image(systemName: symbol).font(.system(size: 40, weight: .regular)).foregroundStyle(Theme.ink.opacity(0.55))
			Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
				.lineLimit(1).truncationMode(.tail)
			HStack(spacing: 6) {
				if let key { KeyCap(label: key.shown, highContrast: highContrast) }
				Text(detail).font(.system(size: 13)).foregroundStyle(Theme.glassInk2(highContrast: highContrast))
			}
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(key.map { "\($0.spoken) \(detail)" } ?? detail)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding(.bottom, 12)
	}

	// MARK: Toast

	@ViewBuilder private var toast: some View {
		if let toast = model.toast {
			HStack(spacing: 12) {
				Image(systemName: toast == .deleted ? "trash" : "exclamationmark.triangle.fill")
					.foregroundStyle(Theme.ink)
				Text(toast.message).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
				if toast == .deleted {
					Button("Undo") { model.request { await model.undo() } }.buttonStyle(.bordered).controlSize(.small)
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

/// The selection lens (brief): radius 21, 5 pt outside the card, behind it: a 3 pt accent stroke over a 12% accent fill.
/// An opaque halo band edges the ring outside and fills the gap inside it (tucking 1 pt under the card), so the ring
/// reaches 3:1 on any glass. One ring for every selection; the lens fades with a deleting card, so no block shows.
struct LensRing: View {
	var removing = false
	static let fillOpacity = Theme.lensFillOpacity
	static let band = Theme.lensHaloWidth + Theme.lensOutset + 1

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: Theme.lensRadius + Theme.lensHaloWidth, style: .continuous)
				.strokeBorder(Theme.lensHalo, lineWidth: Self.band)
			RoundedRectangle(cornerRadius: Theme.lensRadius, style: .continuous)
				.fill(Color.accentColor.opacity(Self.fillOpacity))
				.padding(Theme.lensHaloWidth)
			RoundedRectangle(cornerRadius: Theme.lensRadius, style: .continuous)
				.strokeBorder(Color.accentColor, lineWidth: 3)
				.padding(Theme.lensHaloWidth)
		}
		.padding(-(Theme.lensOutset + Theme.lensHaloWidth))
		.opacity(removing ? 0 : 1)
	}
}

/// After a browse copies: pops in beside Search to confirm the copy and, outside a search, offer ⎋ as the way back.
struct RestoreHintView: View {
	let hint: RestoreHint
	let highContrast: Bool
	/// The card on the clipboard; each new one bounces the check.
	let copied: UUID?
	let reduceMotion: Bool

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "checkmark.circle.fill")
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(.white, Color.accentColor)
				.symbolEffect(.bounce, options: .speed(1.4), value: reduceMotion ? nil : copied)
			Text("Copied")
				.font(.system(size: 12, weight: .semibold))
				.foregroundStyle(Theme.ink)
			if hint != .copied {
				Rectangle().fill(Theme.stroke(hovered: true, highContrast: highContrast)).frame(width: 1, height: 14)
				if hint == .restore { KeyCap(label: "esc", highContrast: highContrast) }
				Text(hint == .restore ? "restores previous" : "Previous clipboard can’t be restored")
					.font(.system(size: 12))
					.foregroundStyle(Theme.ink2(highContrast: highContrast))
					.lineLimit(1)
					.truncationMode(.tail)
			}
		}
		.padding(.leading, 8).padding(.trailing, 12).frame(height: 28)
		.background(Theme.card, in: .capsule)
		.overlay { Capsule().strokeBorder(Theme.stroke(hovered: false, highContrast: highContrast)) }
		.shadow(color: .black.opacity(0.12), radius: 6, y: 2)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Self.spoken(hint))
	}

	static func spoken(_ hint: RestoreHint) -> String {
		switch hint {
		case .restore: "Copied. Escape restores the previous clipboard"
		case .unsaved: "Copied. Previous clipboard can’t be restored"
		case .copied: "Copied"
		}
	}
}

/// A key drawn as a small keycap, for hints that name a key.
struct KeyCap: View {
	let label: String
	let highContrast: Bool

	var body: some View {
		Text(label)
			.font(.system(size: 10, weight: .semibold))
			.foregroundStyle(Theme.ink)
			.padding(.horizontal, 5)
			.frame(minWidth: 26, minHeight: 18)
			.background(Theme.field, in: .rect(cornerRadius: 4, style: .continuous))
			.overlay {
				if highContrast { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.ink, lineWidth: 1) }
			}
	}
}

/// The search capsule: 32 pt tall, 240 wide, 360 with a query. In a narrow strip it gives up width (down to 160)
/// before the count, the chip or the gear do.
struct SearchPill: View {
	@Bindable var model: StripModel
	let focus: SearchFocus

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink.opacity(0.6))
			SearchField(model: model, focus: focus)
		}
		.padding(.horizontal, 10)
		.frame(minWidth: 160, maxWidth: model.query.isEmpty ? 240 : 360, minHeight: 32, maxHeight: 32)
		.background(Theme.field, in: .capsule)
		.layoutPriority(1)
	}
}

/// What VoiceOver reads for a card.
struct CardAccessibility {
	let clip: Clip
	let now: Date

	var preview: String { String(clip.text.prefix(120)) }
	var actions: [String] { CardAction.allCases.map { $0.label(for: clip) } }

	var label: String {
		let kind = CardPresentation(clip: clip).typeLabel
		let source = clip.sourceName ?? "Unknown app"
		let spoken = switch ClipCard.relative(clip.timestamp, now: now) {
		case "Now": "just now"
		case "Yesterday": "yesterday"
		case let age: age + " ago"
		}
		return "\(clip.isPinned ? "Pinned, " : "")\(kind) from \(source), \(spoken): \(preview)"
	}
}

/// The decision for one press. A reference type, so recording it does not invalidate the view.
@MainActor final class PressLatch {
	var number = -1
	var card: UUID?
	var onPin = false
	/// The press number and card of the last release that counted as a card click.
	var lastClick: (Int, UUID)?
}
