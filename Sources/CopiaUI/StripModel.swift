import Foundation
import Observation
import CopiaCore

/// The strip's state and intents. It never touches windows, so it is fully testable headless.
@MainActor
@Observable
public final class StripModel {
	public private(set) var clips: [Clip]
	public private(set) var selectedID: UUID?
	public var query = "" {
		didSet { if query != oldValue { reconcileSelection(preferredIndex: 0) } }
	}
	public var commandHeld = false
	public var paused = false
	public var hoveredID: UUID?
	public private(set) var toast: Toast?
	public private(set) var isClosing = false
	/// Cards are dropped while the strip is hidden so their views and images can be freed.
	public private(set) var cardsMounted = false
	/// Clip IDs currently animating out after a delete.
	public private(set) var removingIDs: Set<UUID> = []

	@ObservationIgnored public var actions: StripActions
	@ObservationIgnored public var animator: Animator
	@ObservationIgnored public var clock: ToastClock
	@ObservationIgnored public var announce: (String) -> Void = { _ in }
	/// Called as soon as closing starts, so the panel can give up key focus.
	@ObservationIgnored public var onCloseStart: () -> Void = {}
	/// Called when the close animation finishes, so the panel can hide and free memory.
	@ObservationIgnored public var onCloseFinish: () -> Void = {}

	@ObservationIgnored private var undoEntry: (clip: Clip, index: Int)?
	@ObservationIgnored private var cancelToast: ToastClock.Cancel?
	@ObservationIgnored private var busy = false
	@ObservationIgnored private var presentation = 0

	public static let toastLifetime: Duration = .seconds(3)

	public init(clips: [Clip], actions: StripActions = .fixtures, animator: Animator = .immediate, clock: ToastClock = .live) {
		self.clips = clips
		self.actions = actions
		self.animator = animator
		self.clock = clock
		selectedID = clips.first?.id
	}

	// MARK: Visible list

	public var visibleClips: [Clip] {
		let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !q.isEmpty else { return clips }
		return clips.filter { clip in
			clip.text.localizedStandardContains(q)
				|| clip.fileNames.contains { $0.localizedStandardContains(q) }
				|| (clip.url?.absoluteString.localizedStandardContains(q) ?? false)
		}
	}

	public var selectedIndex: Int? { visibleClips.firstIndex { $0.id == selectedID } }

	/// The ⌘1–9 badge number for a clip, shown only while ⌘ is held.
	public func badge(for id: UUID) -> Int? {
		guard commandHeld, let i = visibleClips.prefix(9).firstIndex(where: { $0.id == id }) else { return nil }
		return i + 1
	}

	// MARK: Selection

	public func select(_ id: UUID) {
		guard visibleClips.contains(where: { $0.id == id }), id != selectedID else { return }
		animator.run(.lens, { self.selectedID = id }, {})
	}

	public func move(_ delta: Int) {
		let visible = visibleClips
		guard !visible.isEmpty else { return }
		let i = selectedIndex ?? 0
		select(visible[min(max(i + delta, 0), visible.count - 1)].id)
	}

	public func moveToEnd(_ last: Bool) {
		guard let target = last ? visibleClips.last : visibleClips.first else { return }
		select(target.id)
	}

	private func reconcileSelection(preferredIndex: Int) {
		let visible = visibleClips
		if let selectedID, visible.contains(where: { $0.id == selectedID }) { return }
		selectedID = visible.isEmpty ? nil : visible[min(max(preferredIndex, 0), visible.count - 1)].id
	}

	/// Replaces the clip list (B2 pushes store changes here). Keeps the selection when it is still visible.
	public func applySnapshot(_ newClips: [Clip]) {
		let oldIndex = selectedIndex ?? 0
		let inserted = newClips.first.map { first in !clips.contains { $0.id == first.id } } ?? false
		let previewsChanged = newClips.contains { new in
			clips.first { $0.id == new.id }.map { $0.preview != new.preview } ?? false
		}
		let apply = {
			self.clips = newClips
			self.reconcileSelection(preferredIndex: oldIndex)
		}
		if inserted, cardsMounted {
			animator.run(.insert, apply, {})
		} else if previewsChanged, cardsMounted {
			animator.run(.loading, apply, {})
		} else {
			apply()
		}
	}

	// MARK: Delete and undo

	public func deleteSelected() async {
		guard !busy, let id = selectedID, let index = clips.firstIndex(where: { $0.id == id }) else { return }
		busy = true
		defer { busy = false }
		let clip = clips[index]
		let visibleBefore = visibleClips
		let visibleIndex = visibleBefore.firstIndex { $0.id == id } ?? 0
		do {
			try await actions.delete(id)
		} catch {
			show(.error("Couldn't delete: \(error.localizedDescription)"))
			return
		}
		animator.run(.delete, { self.removingIDs.insert(id) }, {
			self.removingIDs.remove(id)
			self.animator.run(.reflow, {
				self.clips.removeAll { $0.id == id }
				let remaining = visibleBefore.filter { $0.id != id }
				self.selectedID = remaining.isEmpty ? nil : remaining[min(visibleIndex, remaining.count - 1)].id
			}, {})
		})
		undoEntry = (clip, index)
		show(.deleted)
		announce(Toast.deleted.message)
	}

	public var canUndo: Bool { undoEntry != nil }

	public func undo() async {
		guard !busy, let entry = undoEntry else { return }
		busy = true
		defer { busy = false }
		do {
			try await actions.restore(entry.clip, entry.index)
		} catch {
			show(.error("Couldn't restore: \(error.localizedDescription)"))
			return
		}
		undoEntry = nil
		dismissToast()
		animator.run(.undo, {
			if !self.clips.contains(where: { $0.id == entry.clip.id }) {
				self.clips.insert(entry.clip, at: min(entry.index, self.clips.count))
			}
			if !self.visibleClips.contains(where: { $0.id == entry.clip.id }) { self.query = "" }
			self.selectedID = entry.clip.id
		}, {})
	}

	// MARK: Paste and actions

	public func paste(plain: Bool) async {
		guard let id = selectedID else { return }
		await paste(id: id, plain: plain)
	}

	/// ⌘1–9 / ⇧⌘1–9: paste the item at that position.
	public func paste(position: Int, plain: Bool) async {
		let visible = visibleClips
		guard (1...9).contains(position), position <= visible.count else { return }
		selectedID = visible[position - 1].id
		await paste(id: visible[position - 1].id, plain: plain)
	}

	private func paste(id: UUID, plain: Bool) async {
		guard !isClosing else { return }
		do {
			let result = try await actions.paste(id, plain) { [weak self] in self?.beginClose() }
			if result == .accessibilityRequired { show(.accessibilityRequired) }
		} catch {
			show(.error("Couldn't paste: \(error.localizedDescription)"))
		}
	}

	public func perform(_ action: CardAction, id: UUID) async {
		if selectedID != id { selectedID = id }
		switch action {
		case .paste: await paste(id: id, plain: false)
		case .pastePlain: await paste(id: id, plain: true)
		case .copy:
			do { try await actions.copy(id) } catch { show(.error("Couldn't copy: \(error.localizedDescription)")) }
		case .delete: await deleteSelected()
		}
	}

	public func openAccessibilitySettings() { actions.openAccessibilitySettings() }

	// MARK: Keys

	/// ⎋ clears the search first, then closes.
	public func escape() {
		if !query.isEmpty { query = "" } else { beginClose() }
	}

	/// ⌫ deletes the selected card only when no search is typed.
	public func backspace() async {
		guard query.isEmpty else { return }
		await deleteSelected()
	}

	// MARK: Open and close

	public func open() {
		presentation += 1
		isClosing = false
		query = ""
		cardsMounted = true
		if selectedID == nil || !clips.contains(where: { $0.id == selectedID }) { selectedID = clips.first?.id }
	}

	public func beginClose() {
		guard cardsMounted, !isClosing else { return }
		isClosing = true
		let generation = presentation
		onCloseStart()
		animator.run(.close, {}, {
			guard generation == self.presentation else { return }
			self.finishClose()
		})
	}

	private func finishClose() {
		cardsMounted = false
		isClosing = false
		commandHeld = false
		hoveredID = nil
		undoEntry = nil
		dismissToast()
		onCloseFinish()
	}

	// MARK: Toasts

	private func show(_ newToast: Toast) {
		cancelToast?()
		toast = newToast
		cancelToast = clock.after(Self.toastLifetime) { [weak self] in
			guard let self, self.toast == newToast else { return }
			self.toast = nil
			if newToast == .deleted { self.undoEntry = nil }
		}
	}

	private func dismissToast() {
		cancelToast?()
		cancelToast = nil
		toast = nil
	}
}
