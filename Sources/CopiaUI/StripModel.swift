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
	public private(set) var selectedID: UUID? {
		// Only an arrow keeps a browse: a press, filter, delete, undo or open that moves the lens off its card ends it.
		didSet { if let target = browseTarget, selectedID != target { dropBrowse() } }
	}
	public var query = "" {
		didSet {
			guard query != oldValue else { return }
			searchRevision += 1
			storeMatches = []
			if query.isEmpty, frozenIDs == nil {
				// Search cleared: the lens goes back to the clipboard's card (or the newest), as when the strip opens.
				// Look first, so a copy made elsewhere since the last poll is not mistaken for that card.
				syncClipboard()
				selectedID = clipboard.flatMap { c in clips.contains { $0.id == c.id } ? c.id : nil } ?? newestID
			} else {
				reconcileSelection(preferredIndex: 0)
			}
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
	/// A pick just changed the clipboard: the chip confirms it until `cancelPickChip` fires.
	private var pickConfirmed = false
	@ObservationIgnored private var cancelPickChip: ToastClock.Cancel?
	/// Undo lasts 3 s from the delete, whatever toast is shown meanwhile.
	@ObservationIgnored private var cancelUndoDeadline: ToastClock.Cancel?
	@ObservationIgnored private var busy = false
	/// A reload can invalidate the store group before its token is delivered to the UI.
	/// Observed: the chip stops offering to restore a card the moment its delete starts.
	private var pendingDelete: Set<UUID> = []
	@ObservationIgnored private var deleteConflicted = false
	@ObservationIgnored private var presentation = 0
	/// Each opening's number, so a capture observed in one opening never fills the restore point of the next.
	public var presentationID: Int { presentation }
	/// Changes as soon as close starts, so a pending delete cannot create undo in a later presentation.
	public private(set) var closeCount = 0

	public static let toastLifetime: Duration = .seconds(3)
	/// How long the Copied chip stays after a click, ⌘C or menu Copy changed the clipboard.
	public static let pickChipLifetime: Duration = .seconds(2)

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
		// A card going away is never copied by a browse still on its way.
		if let target = browseTarget, ids.contains(target) { dropBrowse() }
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

	/// One clipboard write at a time. Later copies wait their turn in order instead of being dropped.
	private var writing = false
	@ObservationIgnored private var writeWaiters: [CheckedContinuation<Void, Never>] = []
	/// The clip this presentation's last write put on the clipboard in full, so a double-click closes without writing it again.
	@ObservationIgnored private var copiedID: UUID?

	// The clipboard follows the lens. A pick is kept; ⎋ puts back the last pick.

	/// The card the clipboard holds, as far as Copia knows: set only by a write that landed, the app's report at open,
	/// or a copy made elsewhere. Never optimistic; nil when unknown.
	public private(set) var clipboard: ClipboardCard?
	/// The last pick, or the card the clipboard held at open. ⎋ after browsing puts it back.
	public private(set) var committed: ClipboardCard?
	/// The card the user last arrowed to. ⌘Y and clicking away write it if it is lit and not yet on the clipboard.
	@ObservationIgnored private var browseTarget: UUID?
	@ObservationIgnored private var settleTimer: ToastClock.Cancel?
	/// Every move, pick, open and close bumps this, so a browse queued before it never writes.
	@ObservationIgnored private var browseGeneration = 0
	/// Counts arrow moves only, so a queued pick can tell whether an arrow came after it (picks bump browseGeneration too).
	@ObservationIgnored private var arrowMoves = 0
	@ObservationIgnored private var lensAfterClose: UUID?
	@ObservationIgnored private var cancelling = false
	/// The arrow count when a queued pick was requested: an arrow pressed after it keeps its browse and the lens.
	@TaskLocal static var pickRequestedAt: Int?
	/// Asks the app to look at the pasteboard now, so a decision is never made on a copy the next poll would have reported.
	@ObservationIgnored public var syncClipboard: () -> Void = {}
	/// Read by the app's writer right before it touches the pasteboard: false means the write is stale and is dropped.
	@ObservationIgnored public private(set) var writeIsCurrent: () -> Bool = { true }
	/// Read by the app's writer: ⎋'s restore must not overwrite a copy made elsewhere since Copia's last write.
	@ObservationIgnored public private(set) var writeRequiresOwnership = false
	/// The lens rests this long before the clipboard follows it.
	public static let browseSettle: Duration = .milliseconds(150)

	private var newestID: UUID? { clips.max { $0.timestamp < $1.timestamp }?.id }

	/// The lens is on the card the clipboard holds.
	public var lensOnClipboard: Bool { selectedID != nil && clipboard?.id == selectedID }

	/// Shown once a browse has changed the clipboard away from the restore point.
	public var restoreHint: RestoreHint? {
		guard let clipboard, clipboard != committed else { return pickConfirmed ? .copied : nil }
		guard query.isEmpty else { return .copied }
		return committed.map(canRestore) == true ? .restore : .unsaved
	}

	/// The restore point is still a card Esc can put back: in history, and not on its way out.
	private func canRestore(_ card: ClipboardCard) -> Bool {
		clips.contains { $0.id == card.id } && !removingIDs.contains(card.id) && !pendingDelete.contains(card.id)
	}

	/// Takes the writer, or waits until the current holder hands it over. Pair every call with `releaseWriter()`.
	private func acquireWriter() async {
		if writing { await withCheckedContinuation { writeWaiters.append($0) } } else { writing = true }
	}

	/// Hands the writer straight to the oldest waiter, so a newer copy can never overtake one already queued.
	private func releaseWriter() {
		if writeWaiters.isEmpty { writing = false } else { writeWaiters.removeFirst().resume() }
	}

	/// Resolve targets synchronously, and never deliver a queued UI command into a later presentation.
	func request(_ operation: @escaping @MainActor () async -> Void) {
		let generation = presentation, close = closeCount, arrows = arrowMoves
		Task {
			guard cardsMounted, !isClosing, presentation == generation, close == closeCount else { return }
			await Self.$pickRequestedAt.withValue(arrows) { await operation() }
		}
	}

	func requestCopy(id: UUID?, plain: Bool, dismiss: Bool) {
		guard let id else { return }
		request { await self.copy(id: id, plain: plain, dismiss: dismiss) }
	}

	/// A pointer release. The press already selected the card, so this never changes the selection.
	/// The first click copies at once; the second click of a double-click closes, writing again only when the
	/// first click's copy did not land, or a copy made elsewhere replaced it.
	func click(_ id: UUID, count: Int) async {
		guard count >= 2 else { return await copy(id: id, plain: false, dismiss: false) }
		dropBrowse(olderThanPick: true)
		let requested = closeCount
		await acquireWriter()
		defer { releaseWriter() }
		guard canWrite(since: requested) else { return }
		syncClipboard()
		if copiedID == id, clipboard == ClipboardCard(id: id) {
			isClosingAfterCopy = true
			beginClose()
		} else {
			await write(id, plain: false, dismiss: true)
		}
	}

	/// A pick: click, ⌘C, Return, ⌘1–9 or a menu or VoiceOver action. It drops any browse not yet written.
	public func copy(id: UUID, plain: Bool, dismiss: Bool) async {
		dropBrowse(olderThanPick: true)
		let requested = closeCount
		await acquireWriter()
		defer { releaseWriter() }
		guard canWrite(since: requested) else { return }
		await write(id, plain: plain, dismiss: dismiss)
	}

	/// A copy that waited out a close belongs to that presentation; it never writes into the next one.
	private func canWrite(since requested: Int) -> Bool {
		storageStatus != .recoveryRequired && cardsMounted && !isClosing && closeCount == requested
	}

	/// The caller holds the writer. `current` is checked again by the app right before the pasteboard write.
	/// Returns whether the card landed; a stale write is dropped quietly, other failures throw.
	private func land(_ card: ClipboardCard, ownership: Bool = false, current: @escaping () -> Bool) async throws -> Bool {
		writeIsCurrent = current
		writeRequiresOwnership = ownership
		defer { writeIsCurrent = { true }; writeRequiresOwnership = false }
		do {
			try await actions.write(card.id, card.plain)
		} catch is CancellationError {
			return false
		}
		clipboard = card
		return true
	}

	/// A pick, or with `browsing` a browse. The caller holds the writer.
	private func write(_ id: UUID, plain: Bool, dismiss: Bool = false, browsing: Bool = false,
		current: (() -> Bool)? = nil) async {
		let close = closeCount, generation = presentation
		let card = ClipboardCard(id: id, plain: plain)
		// What the clipboard held, as far as Copia knows; unknown counts as a change, since this write replaces it.
		let before = clipboard
		copiedID = nil
		do {
			// A browse never overwrites a copy made elsewhere; a pick does.
			guard try await land(card, ownership: browsing, current: current ?? { [unowned self] in
				presentation == generation && closeCount == close
			}), close == closeCount else { return }
			if !plain { copiedID = id }
			// A pick is the new ⎋ restore point; a browse is not.
			if !browsing { committed = card }
			if browsing { endPickChip() } else if before != card, !dismiss { confirmPick() }
			guard dismiss else { return }
			isClosingAfterCopy = true
			beginClose()
		} catch {
			showActionError(error, operation: "copy", close: close)
		}
	}

	/// A copy made elsewhere was saved after a browse already replaced it, with nothing else copied since: it is what
	/// the clipboard held before the browse, so it fills an empty restore point. The clipboard stays where it is.
	/// The card may not be published yet (another reload can win); the chip and Esc offer it once it is.
	public func restorePointSaved(_ card: ClipboardCard, observedIn opening: Int) {
		guard cardsMounted, !isClosing, presentation == opening, committed == nil else { return }
		committed = card
	}

	/// The app saw the clipboard change without Copia: a copy made elsewhere, captured (`card`) or not (nil).
	/// It is the clipboard now, and ⎋ keeps it.
	/// The card may be saved but not yet published by a reload; the lens, the chip and Esc treat it as on the clipboard
	/// once it is.
	public func clipboardChanged(to card: ClipboardCard?) {
		endPickChip()
		clipboard = card
		committed = card
		copiedID = nil
	}

	/// The pasteboard changed without Copia, before any capture says what it holds. A browse not yet written is dropped,
	/// and a close's keep or restore is cancelled, so neither overwrites the newer copy.
	public func clipboardReplaced() {
		endPickChip()
		dropBrowse()
		clipboard = nil
		committed = nil
		copiedID = nil
	}

	// MARK: Browsing


	/// ← or →: move the lens, and the clipboard follows once it rests. Browsing from Search stays in Search,
	/// so ⌫ and typing still edit the query.
	public func browse(_ delta: Int) {
		guard !isClosing else { return }
		let before = selectedID, mode = intent
		move(delta)
		intent = mode
		follow(from: before)
	}

	/// ⌘←, ⌘→, Home or End: jump to the first or last card, and the clipboard follows once the lens rests.
	public func browseToEnd(_ last: Bool) {
		guard !isClosing else { return }
		let before = selectedID, mode = intent
		moveToEnd(last)
		intent = mode
		follow(from: before)
	}

	private func follow(from before: UUID?) {
		guard let id = selectedID, id != before, storageStatus != .recoveryRequired else { return }
		browseGeneration += 1
		arrowMoves += 1
		browseTarget = id
		armSettle()
	}

	private func armSettle() {
		guard let id = browseTarget else { return }
		settleTimer?()
		let generation = browseGeneration
		settleTimer = clock.after(Self.browseSettle) { [weak self] in
			guard let self, generation == browseGeneration else { return }
			settleTimer = nil
			request { await self.writeBrowse(id, generation: generation) }
		}
	}

	/// Cancels a browse not yet written. Picks, opens, closes and deleting its card call it. A queued pick cancels only
	/// a browse from before it was requested; an arrow pressed after it still copies.
	private func dropBrowse(olderThanPick: Bool = false) {
		if olderThanPick, let requested = Self.pickRequestedAt, requested != arrowMoves { return }
		settleTimer?()
		settleTimer = nil
		browseTarget = nil
		browseGeneration += 1
	}

	/// Writes only while the lens is still on `id`, it is still a result, and nothing moved, picked, closed or reopened since.
	private func writeBrowse(_ id: UUID, generation: Int) async {
		let requested = closeCount
		await acquireWriter()
		defer { releaseWriter() }
		syncClipboard()
		let current = { [unowned self] in
			generation == browseGeneration && selectedID == id && !removingIDs.contains(id) && !pendingDelete.contains(id)
				&& visibleClips.contains { $0.id == id } && canWrite(since: requested)
		}
		guard current(), clipboard != ClipboardCard(id: id) else { return }
		await write(id, plain: false, browsing: true, current: current)
	}

	/// A close's write: ⌘Y keeps the lit card, ⎋ restores the last pick that landed. It runs after every write already
	/// queued, and is dropped if the strip reopens or a copy is made elsewhere first; it never overwrites that copy.
	private func writeAfterClose(_ target: ClipboardCard, restoring: Bool, presentation generation: Int, browse: Int) async {
		await acquireWriter()
		defer { releaseWriter() }
		syncClipboard()
		let current = { [unowned self] in
			presentation == generation && storageStatus != .recoveryRequired && browse == browseGeneration
		}
		guard current(), clipboard != target else { return }
		guard (try? await land(target, ownership: true, current: current)) == true else { return }
		if restoring { announce("Previous clipboard restored") }
	}

	public func perform(_ action: CardAction, id: UUID) async {
		guard storageStatus != .recoveryRequired, visibleClips.contains(where: { $0.id == id }) else { return }
		// A queued action keeps the lens where an arrow pressed after it put it.
		if Self.pickRequestedAt.map({ $0 == arrowMoves }) ?? true { selectOnPress(id) }
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

	/// ⎋ clears the search first, then cancels: it closes and, after browsing, puts the last pick back.
	public func escape() {
		if !query.isEmpty { query = "" } else { cancel() }
	}

	public func cancel() {
		guard cardsMounted, !isClosing else { return }
		cancelling = true
		beginClose()
	}

	// MARK: Open and close

	/// Mounts the cards in their hidden position. Call `animateIn()` once the panel is on screen.
	/// `clipboard` is the card the clipboard holds, when the app knows; the lens starts on it, otherwise on the newest card.
	public func open(clipboard known: ClipboardCard? = nil) {
		presentation += 1
		copiedID = nil
		endPickChip()
		dropBrowse()
		// The app reads the pasteboard; a close's write still queued is dropped, so this is what the clipboard holds.
		// A card saved but not yet published is still the clipboard's card and the restore point; the chip and Esc offer
		// it once a reload shows it, and the lens starts on it only if it is shown now.
		clipboard = known
		committed = known
		lensAfterClose = nil
		intent = .results
		frozenIDs = nil
		isClosing = false
		isClosingAfterCopy = false
		query = ""
		appeared = false
		cardsMounted = true
		selectedID = known.flatMap { c in clips.contains { $0.id == c.id } ? c.id : nil } ?? newestID
	}

	/// Called after the open animation, so the panel can refresh its shadow.
	@ObservationIgnored public var onOpenFinish: () -> Void = {}

	public func animateIn() {
		animator.run(.open, { self.appeared = true }, { self.onOpenFinish() })
	}

	public func beginClose() {
		guard cardsMounted, !isClosing else { return }
		let cancel = cancelling, lit = selectedID, target = browseTarget
		cancelling = false
		endPickChip()
		dropBrowse()
		// A copy made elsewhere from here on cancels the keep or restore below.
		let shown = presentation, browse = browseGeneration
		if cancel {
			// ⎋ puts back the last pick that landed. It runs after any write still in flight, and writes only if one changed it.
			if let restore = committed, canRestore(restore) {
				lensAfterClose = restore.id
				Task { await self.writeAfterClose(restore, restoring: true, presentation: shown, browse: browse) }
			}
		} else if !isClosingAfterCopy, let lit, lit == target, clipboard != ClipboardCard(id: lit) {
			// ⌘Y or clicking away keeps the card the user arrowed to.
			Task { await self.writeAfterClose(ClipboardCard(id: lit), restoring: false, presentation: shown, browse: browse) }
		}
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
		if let id = lensAfterClose, clips.contains(where: { $0.id == id }) { selectedID = id }
		lensAfterClose = nil
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

	/// Shows the Copied chip for a pick that changed the clipboard, for `pickChipLifetime` after the latest one.
	private func confirmPick() {
		cancelPickChip?()
		pickConfirmed = true
		cancelPickChip = clock.after(Self.pickChipLifetime) { [weak self] in self?.endPickChip() }
		// The chip appears without focus; VoiceOver hears it too.
		announce("Copied")
	}

	private func endPickChip() {
		cancelPickChip?()
		cancelPickChip = nil
		// Only when shown: opening must not invalidate the top bar for nothing.
		if pickConfirmed { pickConfirmed = false }
	}

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
