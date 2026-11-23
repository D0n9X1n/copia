import Testing
import Foundation
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

/// A manual clock: callbacks run only when the test advances time.
@MainActor
final class ClockProbe {
	private var now: Duration = .zero
	private var scheduled: [(id: Int, deadline: Duration, fire: @MainActor () -> Void)] = []
	private var nextID = 0

	var clock: ToastClock {
		ToastClock { delay, action in
			self.nextID += 1
			let id = self.nextID
			self.scheduled.append((id, self.now + delay, action))
			return { self.scheduled.removeAll { $0.id == id } }
		}
	}

	func advance(by delta: Duration) {
		now += delta
		let due = scheduled.filter { $0.deadline <= now }
		scheduled.removeAll { $0.deadline <= now }
		due.forEach { $0.fire() }
	}
}

enum RigError: Error { case boom }

/// A StripModel wired to spies, a manual clock and a recording animator.
@MainActor
final class StripRig {
	let model: StripModel
	let probe = ClockProbe()
	var requests: [MotionEvent] = []
	var log: [String] = []
	var announcements: [String] = []
	var tokens: [UUID] = []
	var failDelete = false
	var failRestore = false
	var closeStarts = 0
	var closeFinishes = 0

	init(clips: [Clip] = Fixtures.mixed) {
		model = StripModel(clips: clips, animator: .immediate)
		let animator = Animator { [unowned self] event, change, completion in
			requests.append(event)
			change()
			completion()
		}
		model.animator = animator
		model.clock = probe.clock
		model.announce = { [unowned self] in announcements.append($0) }
		model.onCloseStart = { [unowned self] in closeStarts += 1; log.append("closeStart") }
		model.onCloseFinish = { [unowned self] in closeFinishes += 1 }
		model.actions.write = { [unowned self] id, plain in log.append("write \(id) plain=\(plain)") }
		var groups: [UUID: [Clip]] = [:]
		model.actions.delete = { [unowned self] ids in
			if failDelete { throw RigError.boom }
			let token = UUID(); tokens.append(token)
			groups[token] = model.clips.filter { ids.contains($0.id) }
			log.append(contentsOf: ids.map { "delete \($0)" })
			return token
		}
		model.actions.restore = { [unowned self] token in
			if failRestore { throw RigError.boom }
			guard let clips = groups.removeValue(forKey: token) else { throw StripActionError.undoExpired }
			return clips
		}
		model.open()
	}
}

/// Holds a clipboard write mid-flight.
@MainActor
final class WriteGate {
	var waiting: [CheckedContinuation<Void, Never>] = []
	var started: [UUID] = []
	func release() { waiting.forEach { $0.resume() }; waiting = [] }
}

@MainActor
@Suite struct WriteOverlapTests {
	/// Two quick activations must not overwrite the first payload.
	@Test func aSecondWriteWhileOneIsInFlightIsIgnored() async {
		let model = StripModel(clips: Fixtures.mixed, animator: .immediate)
		let gate = WriteGate()
		model.actions.write = { id, _ in
			gate.started.append(id)
			await withCheckedContinuation { gate.waiting.append($0) }
		}
		model.open()
		let first = Task { await model.copy(id: Fixtures.mixed[0].id, plain: false, dismiss: true) }
		while gate.waiting.isEmpty { await Task.yield() }
		let second = Task { await model.copy(id: Fixtures.mixed[1].id, plain: false, dismiss: true) }
		for _ in 0..<50 { await Task.yield() }
		gate.release()
		await first.value
		gate.release()
		await second.value
		#expect(gate.started == [Fixtures.mixed[0].id])
	}
}

@MainActor
@Suite struct StripModelTests {
	@Test func arrowsStopAtTheEnds() {
		let r = StripRig()
		r.model.move(-1)
		#expect(r.model.selectedID == Fixtures.mixed[0].id)
		for _ in 0..<20 { r.model.move(1) }
		#expect(r.model.selectedID == Fixtures.mixed[8].id)
		#expect(r.requests.contains(.lens))
	}

	@Test func snapshotKeepsTheSelection() {
		let r = StripRig()
		r.model.select(Fixtures.mixed[4].id)
		r.model.applySnapshot([Fixtures.extremes[0]] + Fixtures.mixed)
		#expect(r.model.selectedID == Fixtures.mixed[4].id)
		#expect(r.requests.contains(.insert))
	}

	@Test func searchFiltersAndClearsSelectionWhenEmpty() {
		let r = StripRig()
		r.model.query = "release notes"
		#expect(r.model.visibleClips.map(\.id) == [Fixtures.mixed[0].id])
		#expect(r.model.selectedID == Fixtures.mixed[0].id)
		r.model.query = "no such fixture"
		#expect(r.model.visibleClips.isEmpty)
		#expect(r.model.selectedID == nil)
	}

	@Test func searchIsCaseAndDiacriticInsensitiveAndMatchesFileNames() {
		let r = StripRig()
		r.model.query = "ROADMAP"
		#expect(r.model.visibleClips.map(\.id) == [Fixtures.mixed[8].id])
	}

	@Test func deletingAMiddleCardSelectsTheNextAndUndoRestoresIt() async {
		let r = StripRig()
		let id = Fixtures.mixed[4].id
		r.model.select(id)
		await r.model.deleteSelected()
		#expect(!r.model.clips.contains { $0.id == id })
		#expect(r.model.selectedID == Fixtures.mixed[5].id)
		#expect(r.model.toast == .deleted)
		#expect(r.announcements == ["Deleted · ⌘Z to undo"])
		await r.model.undo()
		#expect(r.model.clips[4].id == id)
		#expect(r.model.selectedID == id)
		#expect(r.requests.contains(.delete) && r.requests.contains(.reflow) && r.requests.contains(.undo))
	}

	@Test func deletingTheLastCardSelectsThePrevious() async {
		let r = StripRig()
		r.model.moveToEnd(true)
		await r.model.deleteSelected()
		#expect(r.model.selectedID == Fixtures.mixed[7].id)
	}

	@Test func deletingTheOnlyCardLeavesNoSelection() async {
		let r = StripRig(clips: [Fixtures.mixed[0]])
		await r.model.deleteSelected()
		#expect(r.model.clips.isEmpty)
		#expect(r.model.selectedID == nil)
	}

	@Test func reflowWaitsForTheDeleteCompletion() async {
		let r = StripRig()
		var requests: [MotionEvent] = []
		var finishDelete: (@MainActor () -> Void)?
		r.model.animator = Animator { event, change, completion in
			requests.append(event)
			change()
			if event == .delete { finishDelete = completion } else { completion() }
		}
		let id = r.model.selectedID
		let before = r.model.clips.map(\.id)
		await r.model.deleteSelected()
		#expect(requests == [.delete])
		#expect(r.model.clips.map(\.id) == before)
		#expect(r.model.selectedID == id)
		#expect(finishDelete != nil)
		finishDelete?()
		#expect(requests == [.delete, .reflow])
		#expect(r.model.clips.map(\.id) == before.filter { $0 != id })
	}

	@Test func deleteInFlightDuringCloseDoesNotOfferUndoAfterReopen() async {
		let r = StripRig()
		var release: CheckedContinuation<Void, Never>?
		r.model.actions.delete = { _ in await withCheckedContinuation { release = $0 }; return UUID() }
		let id = r.model.selectedID
		let deleting = Task { await r.model.deleteSelected() }
		while release == nil { await Task.yield() }
		r.model.beginClose()
		r.model.open()
		release?.resume()
		await deleting.value
		#expect(!r.model.canUndo)
		#expect(!r.model.clips.contains { $0.id == id })
		#expect(r.model.toast != .deleted)
	}

	@Test func recoveryStateBlocksStoreActionsAndKeepsItsWarning() async {
		let r = StripRig()
		r.model.storageStatus = .recoveryRequired
		let selected = r.model.selectedID!
		await r.model.copy(id: selected, plain: false, dismiss: true)
		await r.model.perform(.copy, id: selected)
		await r.model.deleteSelected()
		await r.model.undo()
		#expect(r.log.isEmpty)
		#expect(r.model.clips.count == Fixtures.mixed.count)
		#expect(r.model.storageStatus.message.contains("capture paused"))
		r.model.beginClose()
		r.model.open()
		#expect(r.model.storageStatus == .recoveryRequired)
	}

	@Test func anUnknownMutationDoesNotClaimItRolledBack() async {
		let r = StripRig()
		r.model.actions.delete = { _ in throw StripActionError.outcomeUnknown }
		await r.model.deleteSelected()
		#expect(r.model.storageStatus == .recoveryRequired)
		#expect(r.model.toast == .error(StorageStatus.recoveryRequired.message))
		#expect(!r.model.canUndo)
	}

	@Test func startingAnotherDeleteExpiresThePreviousUndo() async {
		let r = StripRig()
		var ended: [UUID] = []
		r.model.onUndoExpired = { ended.append($0) }
		await r.model.deleteSelected()
		let first = r.tokens[0]
		await r.model.deleteSelected()
		#expect(ended == [first])
		#expect(r.model.canUndo)
	}

	@Test func expiredStoreUndoCannotCreateAPhantomCard() async {
		let r = StripRig()
		await r.model.deleteSelected()
		let count = r.model.clips.count
		r.model.actions.restore = { _ in throw StripActionError.undoExpired }
		await r.model.undo()
		#expect(!r.model.canUndo)
		#expect(r.model.clips.count == count)
		#expect(r.model.storageStatus == .ready)
	}

	@Test func undoExpiryDuringActiveRestoreResolvesSafely() async {
		for expired in [false, true] {
			let r = StripRig()
			await r.model.deleteSelected()
			var release: CheckedContinuation<Void, Never>?
			r.model.actions.restore = { _ in
				await withCheckedContinuation { release = $0 }
				if expired { throw StripActionError.undoExpired }; return [Fixtures.mixed[0]]
			}
			let restoring = Task { await r.model.undo() }
			while release == nil { await Task.yield() }
			r.probe.advance(by: .seconds(3))
			release?.resume()
			await restoring.value
			#expect(!r.model.canUndo)
			#expect(r.model.clips.count == Fixtures.mixed.count - (expired ? 1 : 0))
		}
	}

	@Test func deleteDuringCloseDoesNotStartAStorageOperation() async {
		let r = StripRig()
		r.model.animator = Animator { _, change, _ in change() }
		r.model.beginClose()
		let before = r.log
		await r.model.deleteSelected()
		#expect(r.log == before)
		#expect(!r.model.canUndo)
		#expect(r.model.clips.count == Fixtures.mixed.count)
	}

	@Test func undoExpiryNotifiesTheOwnerExactlyOnce() async {
		let r = StripRig()
		var ended: [UUID] = []
		r.model.onUndoExpired = { ended.append($0) }
		await r.model.deleteSelected()
		let selected = r.tokens[0]
		r.probe.advance(by: .seconds(3))
		#expect(ended == [selected])
		r.model.beginClose()
		#expect(ended == [selected])
	}

	@Test func undoDuringTheDeleteAnimationKeepsTheCard() async {
		let r = StripRig()
		var pending: [@MainActor () -> Void] = []
		r.model.animator = Animator { event, change, completion in
			change()
			if event == .delete { pending.append(completion) } else { completion() }
		}
		let id = Fixtures.mixed[3].id
		r.model.select(id)
		await r.model.deleteSelected()
		await r.model.undo()
		pending.forEach { $0() }
		#expect(r.model.clips.contains { $0.id == id })
		#expect(!r.model.removingIDs.contains(id))
		#expect(r.model.selectedID == id)
	}

	@Test func storeMatchesBeyondTheCardTextAreShown() async {
		let r = StripRig()
		let deep = Fixtures.mixed[1].id
		r.model.actions.search = { q in q == "deepword" ? [deep] : [] }
		r.model.query = "deepword"
		#expect(r.model.visibleClips.isEmpty)
		await r.model.searchStore()
		#expect(r.model.visibleClips.map(\.id) == [deep])
		#expect(r.model.selectedID == deep)
	}

	@Test func aStaleStoreSearchIsIgnored() async {
		let r = StripRig()
		r.model.actions.search = { q in
			if q == "old" { r.model.query = "new" }
			return [Fixtures.mixed[3].id]
		}
		r.model.query = "old"
		await r.model.searchStore()
		#expect(r.model.visibleClips.allSatisfy { $0.text.localizedStandardContains("new") })
	}

	@Test func cancellingUndoEndsItAndItsToast() async {
		let r = StripRig()
		let id = Fixtures.mixed[2].id
		r.model.select(id)
		await r.model.deleteSelected()
		r.model.cancelUndo(for: [UUID()])
		#expect(r.model.canUndo)
		r.model.cancelUndo(for: [id])
		#expect(!r.model.canUndo)
		#expect(r.model.toast == nil)
		await r.model.undo()
		#expect(!r.model.clips.contains { $0.id == id })
	}

	@Test func undoClearsAHidingSearch() async {
		let r = StripRig()
		r.model.select(Fixtures.mixed[2].id)
		await r.model.deleteSelected()
		r.model.query = "release"
		await r.model.undo()
		#expect(r.model.query.isEmpty)
		#expect(r.model.selectedID == Fixtures.mixed[2].id)
	}

	@Test func toastLastsThreeSecondsThenUndoExpires() async {
		let r = StripRig()
		await r.model.deleteSelected()
		r.probe.advance(by: .milliseconds(2_999))
		#expect(r.model.toast == .deleted)
		#expect(r.model.canUndo)
		r.probe.advance(by: .milliseconds(1))
		#expect(r.model.toast == nil)
		#expect(!r.model.canUndo)
	}

	@Test func aFailedDeleteKeepsTheData() async {
		let r = StripRig()
		r.failDelete = true
		await r.model.deleteSelected()
		#expect(r.model.clips.count == 9)
		#expect(r.model.selectedID == Fixtures.mixed[0].id)
		if case .error = r.model.toast {} else { Issue.record("expected an error toast") }
	}

	@Test func aFailedRestoreKeepsUndoAvailable() async {
		let r = StripRig()
		await r.model.deleteSelected()
		r.failRestore = true
		await r.model.undo()
		#expect(r.model.canUndo)
		#expect(r.model.clips.count == 8)
	}

	@Test func undoEndsThreeSecondsAfterTheDeleteEvenWhenAnotherToastReplacedIt() async {
		let r = StripRig()
		await r.model.deleteSelected()
		r.probe.advance(by: .seconds(1))
		r.failRestore = true
		await r.model.undo()
		if case .error = r.model.toast {} else { Issue.record("expected an error toast") }
		#expect(r.model.canUndo)
		r.probe.advance(by: .milliseconds(1_999))
		#expect(r.model.canUndo)
		r.probe.advance(by: .milliseconds(1))
		#expect(!r.model.canUndo)
		r.failRestore = false
		await r.model.undo()
		#expect(r.model.clips.count == 8)
	}

	@Test func escapeClearsTheQueryBeforeClosing() {
		let r = StripRig()
		r.model.query = "x"
		r.model.escape()
		#expect(r.model.query.isEmpty)
		#expect(!r.model.isClosing && r.closeStarts == 0)
		r.model.escape()
		#expect(r.closeStarts == 1)
		#expect(r.closeFinishes == 1)
		#expect(!r.model.cardsMounted)
	}

	@Test func resultsDeletionWithAQueryDoesNotDeleteHiddenClips() async {
		let r = StripRig(); r.model.query = "release"
		await r.model.deleteSelected()
		#expect(r.model.clips == Array(Fixtures.mixed.dropFirst()))
		await r.model.deleteSelected()
		#expect(r.tokens.count == 1)
	}

	@Test func holdingCommandShowsBadgesOneThroughNine() {
		let r = StripRig()
		#expect(r.model.badge(at: 0) == nil)
		r.model.commandHeld = true
		#expect(r.model.badge(at: 0) == 1)
		#expect(r.model.badge(at: 8) == 9)
	}

	@Test func clickSelectsAndMenuActionsDispatch() async {
		let r = StripRig()
		r.model.select(Fixtures.mixed[3].id)
		#expect(r.model.selectedID == Fixtures.mixed[3].id)
		await r.model.perform(.copy, id: Fixtures.mixed[5].id)
		#expect(r.log == ["write \(Fixtures.mixed[5].id) plain=false"])
		#expect(r.model.cardsMounted)
		await r.model.perform(.copyPlain, id: Fixtures.mixed[6].id)
		#expect(r.log.contains("write \(Fixtures.mixed[6].id) plain=true"))
	}

	@Test func aStaleCloseCompletionDoesNotHideAReopenedStrip() {
		let r = StripRig()
		var pending: (@MainActor () -> Void)?
		r.model.animator = Animator { event, change, completion in
			change()
			if event == .close { pending = completion } else { completion() }
		}
		r.model.beginClose()
		r.model.open()
		pending?()
		#expect(r.model.cardsMounted)
	}

	@Test func reducedMotionAnimatorJumpsTheLens() {
		var curves: [MotionCurve] = []
		let animator = Animator { event, change, completion in
			curves.append(Motion.value(event, reduced: true))
			change()
			completion()
		}
		let model = StripModel(clips: Fixtures.mixed, animator: animator)
		model.open()
		model.move(1)
		#expect(curves == [.none])
	}
}

extension StripModelTests {
	@Test func frozenFilteredGroupDoesNotGrowFromAnInsertOrLateStoreMatches() async {
		let clips = Array(Fixtures.tenThousand.prefix(180))
		let model = StripModel(clips: clips)
		model.query = "History item 1"
		let expected = Set(model.visibleClips.map(\.id))
		model.selectAllResults()
		#expect(expected.count > 9 && model.selectedIDs == expected)
		var new = clips[0]; new.id = UUID()
		model.applySnapshot([new] + clips.dropFirst())
		model.actions.search = { _ in [clips[1].id] }
		await model.searchStore()
		#expect(model.selectedIDs == expected.subtracting([clips[0].id]))
		model.selectOnPress(model.selectedID!)
		#expect(model.selectedIDs.count == 1)
	}

	@Test func aLateFirstAResponseCannotOverwriteTheSecondA() async {
		let r = StripRig(), id = Fixtures.mixed[5].id
		r.model.query = "unseen"
		r.model.actions.search = { _ in
			r.model.query = "different"; r.model.query = "unseen"
			return [id]
		}
		await r.model.searchStore()
		#expect(r.model.visibleClips.isEmpty)
	}

	@Test func previewChangesAreComparedByIDNotByRow() {
		let r = StripRig()
		var reordered = Array(Fixtures.mixed.reversed())
		reordered[0].preview = .failed
		r.model.applySnapshot(reordered)
		#expect(r.requests == [.loading])
		r.model.applySnapshot(Fixtures.mixed)
		#expect(r.requests == [.loading, .loading])
		r.model.applySnapshot(Array(Fixtures.mixed.reversed()))
		#expect(r.requests == [.loading, .loading])
	}
}

extension StripModelTests {
	@Test func deletingAFrozenGroupIncludesPinsAndRestoresMembersInCurrentOrder() async {
		var clips = Array(Fixtures.tenThousand.prefix(12)); clips[10].isPinned = true
		let model = StripModel(clips: clips)
		let group = UUID(); var deleted: [UUID] = []
		model.actions.delete = { ids in deleted = ids; return group }
		model.actions.restore = { token in #expect(token == group); return clips }
		model.open(); model.selectAllResults()
		var new = Fixtures.extremes[0]; new.timestamp = Fixtures.now.addingTimeInterval(1)
		model.applySnapshot([new] + clips)
		await model.deleteSelected()
		#expect(deleted == clips.map(\.id))
		#expect(model.clips == [new])
		await model.undo()
		#expect(model.clips == [clips[10], new] + clips.filter { !$0.isPinned })
		#expect(model.selectedIDs == Set(deleted))
	}

	@Test func recopyOfNonprimaryMemberCancelsTheWholeToken() async {
		let r = StripRig()
		r.model.selectAllResults()
		await r.model.deleteSelected()
		r.model.cancelUndo(for: [Fixtures.mixed.last!.id])
		await r.model.undo()
		#expect(!r.model.canUndo && r.model.clips.isEmpty)
	}
}

extension StripModelTests {
	@Test func onlySuccessfulActivationClosesAndMarksItsCloseStart() async {
		let r = StripRig(), id = Fixtures.mixed[0].id
		var copyCloses: [Bool] = []
		r.model.onCloseStart = { copyCloses.append(r.model.isClosingAfterCopy) }
		r.model.actions.write = { _, _ in throw RigError.boom }
		await r.model.copy(id: id, plain: true, dismiss: true)
		#expect(r.model.cardsMounted && copyCloses.isEmpty)
		r.model.actions.write = { _, _ in }
		await r.model.copy(id: id, plain: false, dismiss: false)
		#expect(r.model.cardsMounted && copyCloses.isEmpty)
		await r.model.copy(id: id, plain: true, dismiss: true)
		#expect(copyCloses == [true] && !r.model.cardsMounted)
		r.model.open(); r.model.beginClose()
		#expect(copyCloses == [true, false])
	}

	@Test func lateCopySuccessOrFailureCannotCloseOrWarnInAReopenedStrip() async {
		for fail in [true, false] {
			let r = StripRig(), gate = WriteGate()
			r.model.actions.write = { _, _ in
				await withCheckedContinuation { gate.waiting.append($0) }
				if fail { throw RigError.boom }
			}
			let copying = Task { await r.model.copy(id: Fixtures.mixed[1].id, plain: false, dismiss: true) }
			while gate.waiting.isEmpty { await Task.yield() }
			r.model.beginClose(); r.model.open(); gate.release()
			await copying.value
			#expect(r.model.cardsMounted && r.model.toast == nil && r.closeStarts == 1)
		}
	}
}

extension StripModelTests {
	@Test func unchangedAndReorderedSnapshotsDoAtMostOneIndexedPreviewLookupPerRow() {
		let rows = Array(Fixtures.tenThousand.prefix(2_000)), model = StripModel(clips: rows)
		model.open()
		for next in [rows, Array(rows.reversed())] {
			let before = Diagnostics.previewComparisons
			model.applySnapshot(next)
			#expect(Diagnostics.previewComparisons - before == rows.count)
		}
	}
}

extension StripModelTests {
	@Test func recopyDeliveredBeforeDeleteReturnsDoesNotEraseTheNewCopyOrOfferUndo() async {
		let r = StripRig(), id = Fixtures.mixed[1].id
		r.model.selectAllResults()
		var recopy = Fixtures.mixed[1]; recopy.timestamp = .distantFuture
		r.model.actions.delete = { _ in
			r.model.cancelUndo(for: [id]); r.model.applySnapshot([recopy])
			return UUID()
		}
		await r.model.deleteSelected()
		#expect(r.model.clips == [recopy] && !r.model.canUndo && r.model.toast == nil)
	}
}

/// #22: a pointer click copies at once; the second click of a double-click closes without a second write.
extension StripModelTests {
	@Test func aSingleClickSelectsAndCopiesThePointedCardWithoutClosing() async {
		let r = StripRig(), id = Fixtures.mixed[3].id
		r.model.selectOnPress(id)
		await r.model.click(id, count: 1)
		#expect(r.model.selectedID == id)
		#expect(r.log == ["write \(id) plain=false"])
		#expect(r.model.cardsMounted && !r.model.isClosing)
	}

	@Test func aDoubleClickClosesAfterTheFirstClickWithoutWritingAgain() async {
		let r = StripRig(), id = Fixtures.mixed[2].id
		await r.model.click(id, count: 1)
		await r.model.click(id, count: 2)
		#expect(r.log == ["write \(id) plain=false", "closeStart"])
		#expect(r.model.closeCount == 1 && !r.model.cardsMounted)
	}

	@Test func aSecondClickOnAnotherCardCopiesThatCardAndCloses() async {
		let r = StripRig(), first = Fixtures.mixed[1].id, second = Fixtures.mixed[4].id
		r.model.selectOnPress(first)
		await r.model.click(first, count: 1)
		r.model.selectOnPress(second)
		await r.model.click(second, count: 2)
		#expect(r.model.selectedID == second)
		#expect(r.log == ["write \(first) plain=false", "write \(second) plain=false", "closeStart"])
	}

	@Test func aDoubleClickAfterAFailedFirstCopyRetriesAndCloses() async {
		let r = StripRig(), id = Fixtures.mixed[2].id
		var fail = true
		r.model.actions.write = { id, plain in
			if fail { fail = false; throw RigError.boom }
			r.log.append("write \(id) plain=\(plain)")
		}
		await r.model.click(id, count: 1)
		#expect(r.model.cardsMounted)
		await r.model.click(id, count: 2)
		#expect(r.log == ["write \(id) plain=false", "closeStart"])
	}

	@Test func reopeningForgetsTheLastClickedCopy() async {
		let r = StripRig(), id = Fixtures.mixed[2].id
		await r.model.click(id, count: 1)
		r.model.beginClose(); r.model.open(); r.log.removeAll()
		await r.model.click(id, count: 2)
		#expect(r.log == ["write \(id) plain=false", "closeStart"])
	}
}

extension WriteOverlapTests {
	@Test func aDoubleClickDuringTheFirstClicksWriteClosesWhenThatWriteLands() async {
		let model = StripModel(clips: Fixtures.mixed, animator: .immediate), gate = WriteGate(), id = Fixtures.mixed[2].id
		model.actions.write = { id, _ in
			gate.started.append(id)
			await withCheckedContinuation { gate.waiting.append($0) }
		}
		model.open()
		let first = Task { await model.click(id, count: 1) }
		while gate.waiting.isEmpty { await Task.yield() }
		let second = Task { await model.click(id, count: 2) }
		for _ in 0..<50 { await Task.yield() }
		#expect(model.cardsMounted && !model.isClosing)
		gate.release()
		await first.value
		await second.value
		#expect(gate.started == [id])
		#expect(model.closeCount == 1 && !model.cardsMounted)
	}
}

/// Review follow-ups for #22: no click is dropped, and only this presentation's successful write counts as copied.
extension StripModelTests {
	@Test func aFailedWriteForgetsTheEarlierCopySoTheDoubleClickRetries() async {
		let r = StripRig(), id = Fixtures.mixed[2].id
		var failNext = false
		r.model.actions.write = { id, plain in
			if failNext { failNext = false; throw RigError.boom }
			r.log.append("write \(id) plain=\(plain)")
		}
		await r.model.click(id, count: 1)
		failNext = true
		await r.model.click(id, count: 1)
		await r.model.click(id, count: 2)
		#expect(r.log == ["write \(id) plain=false", "write \(id) plain=false", "closeStart"])
	}

	@Test func aClickStillCopiesWhenTypingHidesTheCardBeforeItRuns() async {
		let r = StripRig(), id = Fixtures.mixed[2].id
		r.model.query = "zzzz-no-such-text"
		try? #require(!r.model.visibleClips.contains { $0.id == id })
		await r.model.click(id, count: 1)
		#expect(r.log == ["write \(id) plain=false"])
	}
}

extension WriteOverlapTests {
	@Test func aClickOnAnotherCardDuringAWriteWaitsAndThenCopiesThatCard() async {
		let model = StripModel(clips: Fixtures.mixed, animator: .immediate), gate = WriteGate()
		let a = Fixtures.mixed[1].id, b = Fixtures.mixed[4].id
		model.actions.write = { id, _ in
			gate.started.append(id)
			await withCheckedContinuation { gate.waiting.append($0) }
		}
		model.open()
		let first = Task { await model.click(a, count: 1) }
		while gate.waiting.isEmpty { await Task.yield() }
		model.selectOnPress(b)
		let second = Task { await model.click(b, count: 1) }
		for _ in 0..<50 { await Task.yield() }
		#expect(gate.started == [a] && model.selectedID == b)
		gate.release()
		await first.value
		for _ in 0..<1_000 where gate.waiting.isEmpty { await Task.yield() }
		#expect(gate.started == [a, b])
		gate.release()
		await second.value
		#expect(model.cardsMounted && !model.isClosing)
	}

	@Test func aWriteThatLandsAfterReopeningDoesNotCountForTheNewPresentation() async {
		let model = StripModel(clips: Fixtures.mixed, animator: .immediate), gate = WriteGate(), id = Fixtures.mixed[2].id
		model.actions.write = { id, _ in
			gate.started.append(id)
			await withCheckedContinuation { gate.waiting.append($0) }
		}
		model.open()
		let first = Task { await model.click(id, count: 1) }
		while gate.waiting.isEmpty { await Task.yield() }
		model.beginClose(); model.open()
		gate.release()
		await first.value
		var writes: [UUID] = []
		model.actions.write = { id, _ in writes.append(id) }
		await model.click(id, count: 2)
		#expect(writes == [id])
		#expect(model.closeCount == 2 && !model.cardsMounted)
	}
}

extension WriteOverlapTests {
	@Test func aCopyQueuedBehindAWriteNeverRunsInTheNextPresentation() async {
		let model = StripModel(clips: Fixtures.mixed, animator: .immediate), gate = WriteGate()
		let a = Fixtures.mixed[1].id, b = Fixtures.mixed[4].id
		model.actions.write = { id, _ in
			gate.started.append(id)
			await withCheckedContinuation { gate.waiting.append($0) }
		}
		model.open()
		let first = Task { await model.click(a, count: 1) }
		while gate.waiting.isEmpty { await Task.yield() }
		let queued = Task { await model.click(b, count: 1) }
		for _ in 0..<50 { await Task.yield() }
		model.beginClose(); model.open()
		gate.release()
		await first.value
		await queued.value
		#expect(gate.started == [a])
		#expect(model.cardsMounted && !model.isClosing)
	}
}

/// Review round 2: a release copies without touching the selection, and queued copies run strictly in order.
extension StripModelTests {
	@Test func aReleaseCopiesItsCardButLeavesANewerKeyboardSelection() async {
		let r = StripRig(), a = Fixtures.mixed[2].id
		r.model.selectOnPress(a)
		r.model.move(1)
		let moved = r.model.selectedID
		try? #require(moved != a)
		await r.model.click(a, count: 1)
		#expect(r.model.selectedID == moved)
		#expect(r.log == ["write \(a) plain=false"])
	}
}

extension WriteOverlapTests {
	@Test func aNewClickCannotOvertakeOneAlreadyWaiting() async {
		let model = StripModel(clips: Fixtures.mixed, animator: .immediate), gate = WriteGate()
		let a = Fixtures.mixed[1].id, b = Fixtures.mixed[4].id, c = Fixtures.mixed[6].id
		var third: Task<Void, Never>?
		model.actions.write = { id, _ in
			gate.started.append(id)
			guard id == a else { return }
			await withCheckedContinuation { gate.waiting.append($0) }
			// C arrives in the instant A's write returns, before B's turn has run.
			third = Task { await model.click(c, count: 1) }
		}
		model.open()
		let first = Task { await model.click(a, count: 1) }
		while gate.waiting.isEmpty { await Task.yield() }
		let second = Task { await model.click(b, count: 1) }
		for _ in 0..<50 { await Task.yield() }
		gate.release()
		await first.value; await second.value; await third?.value
		#expect(gate.started == [a, b, c])
	}
}
