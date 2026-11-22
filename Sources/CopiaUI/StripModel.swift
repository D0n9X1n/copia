import Foundation
import Observation
import CopiaCore

/// The strip's state and intents. It never touches windows, so it is fully testable headless.
@MainActor
@Observable
public final class StripModel {
	public enum InputIntent { case results, search }
	public var intent: InputIntent = .results
	/// Nil means a single primary; an empty frozen group must never acquire the next match.
	private var frozenIDs: Set<UUID>?
	public var selectedIDs: Set<UUID> { frozenIDs ?? selectedID.map { [$0] } ?? [] }
	var groupCount: Int? { frozenIDs?.count }
	func isSelected(_ id: UUID) -> Bool { frozenIDs?.contains(id) ?? (selectedID == id) }
	public private(set) var clips: [Clip]
	public private(set) var selectedID: UUID?
	public var query = "" {
		didSet {
			guard query != oldValue else { return }
			searchRevision += 1
			storeMatches = []
			reconcileSelection(preferredIndex: 0)
			searchTask?.cancel()
			searchTask = Task { [weak self] in
				try? await Task.sleep(for: Self.searchDelay)
				guard !Task.isCancelled else { return }
				await self?.searchStore()
			}
		}
	}
	public var commandHeld = false
	public var paused = false
	public var storageStatus: StorageStatus = .ready
	public var hoveredID: UUID?
	public private(set) var toast: Toast?
	public private(set) var isClosing = false
	public private(set) var isClosingAfterCopy = false
	/// Cards are dropped while the strip is hidden so their views and images can be freed.
	public private(set) var cardsMounted = false
	/// Drives the open/close slide: false = below and transparent, true = in place.
	public private(set) var appeared = false
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
	@ObservationIgnored public var onUndoExpired: (UUID) -> Void = { _ in }

	/// Full-text matches for the current query revision.
	private var storeMatches: Set<UUID> = []
	@ObservationIgnored private var searchRevision = 0
	@ObservationIgnored private var searchTask: Task<Void, Never>?
	/// Typing pauses this long before the store is searched.
	public static let searchDelay: Duration = .milliseconds(120)
	@ObservationIgnored private var undoEntry: (token: UUID, members: Set<UUID>, primary: UUID)?
	@ObservationIgnored private var cancelToast: ToastClock.Cancel?
	/// Undo lasts 3 s from the delete, whatever toast is shown meanwhile.
	@ObservationIgnored private var cancelUndoDeadline: ToastClock.Cancel?
	@ObservationIgnored private var busy = false
	/// A reload can invalidate the store group before its token is delivered to the UI.
	@ObservationIgnored private var pendingDelete: Set<UUID> = []
	@ObservationIgnored private var deleteConflicted = false
	@ObservationIgnored private var presentation = 0
	/// Changes as soon as close starts, so a pending delete cannot create undo in a later presentation.
	public private(set) var closeCount = 0

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
		let stored = storeMatches
		return clips.filter { clip in
			stored.contains(clip.id)
				|| clip.text.localizedStandardContains(q)
				|| clip.fileNames.contains { $0.localizedStandardContains(q) }
				|| (clip.url?.absoluteString.localizedStandardContains(q) ?? false)
		}
	}

	/// Adds the store's matches for the current query, which reach past the card text. A result for an older query is dropped.
	public func searchStore() async {
		let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !q.isEmpty else { return }
		searchRevision += 1
		let revision = searchRevision
		let found = await actions.search(q)
		guard revision == searchRevision else { return }
		storeMatches = found
		reconcileSelection(preferredIndex: 0)
	}

	public var selectedIndex: Int? { visibleClips.firstIndex { $0.id == selectedID } }

	/// The ⌘1–9 badge number for a clip, shown only while ⌘ is held.
	public func badge(at index: Int) -> Int? { commandHeld && (0..<9).contains(index) ? index + 1 : nil }

	// MARK: Selection

	public func selectAllResults() {
		let visible = visibleClips
		frozenIDs = Set(visible.map(\.id))
		if selectedID == nil { selectedID = visible.first?.id }
	}

	public func selectOnPress(_ id: UUID) {
		intent = .results
		guard selectedID != id || frozenIDs != nil else { return }
		frozenIDs = nil
		selectedID = id
	}

	public func select(_ id: UUID) {
		guard visibleClips.contains(where: { $0.id == id }) else { return }
		intent = .results
		frozenIDs = nil
		guard id != selectedID else { return }
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
		if let frozenIDs {
			let remaining = frozenIDs.intersection(visible.lazy.map(\.id))
			self.frozenIDs = remaining
			if let selectedID, remaining.contains(selectedID) { return }
			selectedID = visible.first { remaining.contains($0.id) }?.id
			return
		}
		if let selectedID, visible.contains(where: { $0.id == selectedID }) { return }
		selectedID = visible.isEmpty ? nil : visible[min(max(preferredIndex, 0), visible.count - 1)].id
	}

	/// Replaces the clip list (B2 pushes store changes here). Keeps the selection when it is still visible.
	public func applySnapshot(_ newClips: [Clip]) {
		let oldIndex = selectedIndex ?? 0
		let previews = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.preview) })
		let inserted = newClips.first.map { previews[$0.id] == nil } ?? false
		let previewsChanged = newClips.contains { new in
			Diagnostics.previewComparisons += 1
			return previews[new.id].map { $0 != new.preview } ?? false
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
		await delete(ids: selectedIDs)
	}

	func delete(ids: Set<UUID>) async {
		guard storageStatus != .recoveryRequired, !isClosing, !busy, !ids.isEmpty else { return }
		let ordered = visibleClips.lazy.map(\.id).filter(ids.contains)
		let targets = Array(ordered)
		guard targets.count == ids.count, let first = targets.first, removingIDs.isDisjoint(with: ids) else { return }
		let primary = selectedID.flatMap { ids.contains($0) ? $0 : nil } ?? first
		let index = selectedIndex ?? 0, close = closeCount
		busy = true
		pendingDelete = ids
		deleteConflicted = false
		defer { busy = false; pendingDelete = [] }
		let token: UUID
		do {
			token = try await actions.delete(targets)
		} catch {
			showActionError(error, operation: "delete", close: close)
			return
		}
		guard !deleteConflicted else { return }
		guard closeCount == close else {
			clips.removeAll { ids.contains($0.id) }
			reconcileSelection(preferredIndex: index)
			return
		}
		animator.run(.delete, { self.removingIDs.formUnion(ids) }, {
			// An intervening undo or recopy can already have reclaimed these cards.
			let stillRemoving = self.removingIDs.intersection(ids)
			guard !stillRemoving.isEmpty else { return }
			self.removingIDs.subtract(stillRemoving)
			self.animator.run(.reflow, {
				self.clips.removeAll { stillRemoving.contains($0.id) }
				if self.frozenIDs == ids { self.frozenIDs = nil }
				self.reconcileSelection(preferredIndex: index)
			}, {})
		})
		endUndo(expired: true)
		undoEntry = (token, ids, primary)
		cancelUndoDeadline = clock.after(Self.toastLifetime) { [weak self] in
			guard let self, self.undoEntry?.token == token else { return }
			self.endUndo(expired: true)
		}
		show(.deleted)
		announce(Toast.deleted.message)
	}

	public var canUndo: Bool { undoEntry != nil }

	/// A recopy of any member invalidates the whole transaction.
	public func cancelUndo(for ids: Set<UUID>) {
		if !ids.isDisjoint(with: pendingDelete) { deleteConflicted = true }
		removingIDs.subtract(ids)
		guard let entry = undoEntry, !ids.isDisjoint(with: entry.members) else { return }
		endUndo()
		if toast == .deleted { dismissToast() }
	}

	public func undo() async {
		guard storageStatus != .recoveryRequired, !busy, !isClosing, let entry = undoEntry else { return }
		busy = true
		defer { busy = false }
		let close = closeCount
		let restored: [Clip]
		do {
			restored = try await actions.restore(entry.token)
		} catch {
			showActionError(error, operation: "restore", close: close)
			return
		}
		endUndo()
		removingIDs.subtract(entry.members)
		animator.run(.undo, {
			// A fresh store snapshot can already include a newer recopy or preview. Keep it.
			let existing = Set(self.clips.map(\.id))
			self.clips = (self.clips + restored.filter { !existing.contains($0.id) }).sorted(by: Self.historyOrder)
			guard close == self.closeCount else { return }
			self.dismissToast()
			if !entry.members.isSubset(of: self.visibleClips.lazy.map(\.id)) { self.query = "" }
			self.frozenIDs = entry.members.count > 1 ? entry.members : nil
			self.selectedID = entry.primary
			self.reconcileSelection(preferredIndex: 0)
		}, {})
	}

	/// Matches store ordering: pin, last copied, then content key (the UUID is its prefix).
	nonisolated private static func historyOrder(_ a: Clip, _ b: Clip) -> Bool {
		if a.isPinned != b.isPinned { return a.isPinned }
		if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
		return a.id < b.id
	}

	// MARK: Card actions

	private var writing = false

	/// Resolve targets synchronously, and never deliver a queued UI command into a later presentation.
	func request(_ operation: @escaping @MainActor () async -> Void) {
		let generation = presentation, close = closeCount
		Task {
			guard cardsMounted, !isClosing, presentation == generation, close == closeCount else { return }
			await operation()
		}
	}

	func requestCopy(id: UUID?, plain: Bool, dismiss: Bool) {
		guard let id else { return }
		request { await self.copy(id: id, plain: plain, dismiss: dismiss) }
	}

	public func copy(id: UUID, plain: Bool, dismiss: Bool) async {
		guard storageStatus != .recoveryRequired, cardsMounted, !isClosing, !writing else { return }
		let close = closeCount
		writing = true
		defer { writing = false }
		do {
			try await actions.write(id, plain)
			guard dismiss, close == closeCount else { return }
			isClosingAfterCopy = true
			beginClose()
		} catch {
			showActionError(error, operation: "copy", close: close)
		}
	}

	public func perform(_ action: CardAction, id: UUID) async {
		guard storageStatus != .recoveryRequired, visibleClips.contains(where: { $0.id == id }) else { return }
		selectOnPress(id)
		switch action {
		case .activate, .copyPlain, .copy: await copy(id: id, plain: action == .copyPlain, dismiss: action != .copy)
		case .delete: await delete(ids: [id])
		case .pin: await togglePin(id)
		}
	}

	func togglePin(_ id: UUID) async {
		guard storageStatus != .recoveryRequired, !busy, !isClosing, let clip = clips.first(where: { $0.id == id }) else { return }
		let pinned = !clip.isPinned, close = closeCount
		busy = true
		defer { busy = false }
		do {
			try await actions.setPinned(id, pinned)
			if let i = clips.firstIndex(where: { $0.id == id }), clips[i].isPinned != pinned {
				clips[i].isPinned = pinned
				clips.sort(by: Self.historyOrder)
			}
		} catch {
			showActionError(error, operation: pinned ? "pin" : "unpin", close: close)
		}
	}

	// MARK: Keys

	/// ⎋ clears the search first, then closes.
	public func escape() {
		if !query.isEmpty { query = "" } else { beginClose() }
	}

	// MARK: Open and close

	/// Mounts the cards in their hidden position. Call `animateIn()` once the panel is on screen.
	public func open() {
		presentation += 1
		intent = .results
		frozenIDs = nil
		isClosing = false
		isClosingAfterCopy = false
		query = ""
		appeared = false
		cardsMounted = true
		if selectedID == nil || !clips.contains(where: { $0.id == selectedID }) { selectedID = clips.first?.id }
	}

	/// Called after the open animation, so the panel can refresh its shadow.
	@ObservationIgnored public var onOpenFinish: () -> Void = {}

	public func animateIn() {
		animator.run(.open, { self.appeared = true }, { self.onOpenFinish() })
	}

	public func beginClose() {
		guard cardsMounted, !isClosing else { return }
		isClosing = true
		closeCount += 1
		endUndo()
		dismissToast()
		let generation = presentation
		onCloseStart()
		animator.run(.close, { self.appeared = false }, {
			guard generation == self.presentation else { return }
			self.finishClose()
		})
	}

	private func finishClose() {
		cardsMounted = false
		isClosing = false
		isClosingAfterCopy = false
		commandHeld = false
		hoveredID = nil
		endUndo()
		dismissToast()
		onCloseFinish()
	}

	// MARK: Toasts

	private func showActionError(_ error: Error, operation: String, close: Int) {
		guard close == closeCount || error as? StripActionError == .outcomeUnknown else { return }
		switch error as? StripActionError {
		case .outcomeUnknown:
			storageStatus = .recoveryRequired
			show(.error(storageStatus.message))
		case .undoExpired:
			endUndo()
			show(.error("Undo has expired."))
		case nil:
			show(.error("Couldn't \(operation): \(error.localizedDescription)"))
		}
	}

	private func show(_ newToast: Toast) {
		cancelToast?()
		toast = newToast
		cancelToast = clock.after(Self.toastLifetime) { [weak self] in
			guard let self, self.toast == newToast else { return }
			self.toast = nil
		}
	}

	private func endUndo(expired: Bool = false) {
		let id = undoEntry?.token
		undoEntry = nil
		cancelUndoDeadline?()
		cancelUndoDeadline = nil
		if expired, let id { onUndoExpired(id) }
	}

	private func dismissToast() {
		cancelToast?()
		cancelToast = nil
		toast = nil
	}
}
