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
	var pasteResult: PasteResult = .pasted
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
		model.actions = StripActions(
			paste: { [unowned self] id, plain, beginClose in
				log.append("paste \(id) plain=\(plain)")
				if pasteResult == .accessibilityRequired { return .accessibilityRequired }
				beginClose()
				log.append("sendPaste")
				return pasteResult
			},
			copy: { [unowned self] id in log.append("copy \(id)") },
			delete: { [unowned self] id in
				if failDelete { throw RigError.boom }
				log.append("delete \(id)")
			},
			restore: { [unowned self] clip, index in
				if failRestore { throw RigError.boom }
				log.append("restore \(clip.id) at \(index)")
			},
			openAccessibilitySettings: { [unowned self] in log.append("openAX") }
		)
		model.open()
	}
}

/// Holds a paste mid-flight so a second request can arrive while the first waits for the target app.
@MainActor
final class PasteGate {
	var waiting: [CheckedContinuation<Void, Never>] = []
	var started: [UUID] = []
	func release() { waiting.forEach { $0.resume() }; waiting = [] }
}

@MainActor
@Suite struct PasteOverlapTests {
	/// Two quick pastes (⌘1 then ⌘2) must not both write: the second would replace the first's payload before its ⌘V.
	@Test func aSecondPasteWhileOneIsInFlightIsIgnored() async {
		let model = StripModel(clips: Fixtures.mixed, animator: .immediate)
		let gate = PasteGate()
		model.actions = StripActions(
			paste: { id, _, _ in
				gate.started.append(id)
				await withCheckedContinuation { gate.waiting.append($0) }
				return .pasted
			},
			copy: { _ in }, delete: { _ in }, restore: { _, _ in }, openAccessibilitySettings: {})
		model.open()
		let first = Task { await model.paste(position: 1, plain: false) }
		while gate.waiting.isEmpty { await Task.yield() }
		let second = Task { await model.paste(position: 2, plain: false) }
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
		r.model.actions.delete = { _ in await withCheckedContinuation { release = $0 } }
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
		await r.model.paste(plain: false)
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
		let first = r.model.selectedID!
		await r.model.deleteSelected()
		await r.model.deleteSelected()
		#expect(ended == [first])
		#expect(r.model.canUndo)
	}

	@Test func expiredStoreUndoCannotCreateAPhantomCard() async {
		let r = StripRig()
		await r.model.deleteSelected()
		let count = r.model.clips.count
		r.model.actions.restore = { _, _ in throw StripActionError.undoExpired }
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
			r.model.actions.restore = { _, _ in
				await withCheckedContinuation { release = $0 }
				if expired { throw StripActionError.undoExpired }
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
		let selected = r.model.selectedID!
		await r.model.deleteSelected()
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

	@Test func backspaceIsIgnoredWhileAQueryIsTyped() async {
		let r = StripRig()
		r.model.query = "release"
		await r.model.backspace()
		#expect(r.model.clips.count == 9)
		r.model.query = ""
		await r.model.backspace()
		#expect(r.model.clips.count == 8)
	}

	@Test func pasteBeginsClosingBeforeSendingThePaste() async {
		let r = StripRig()
		await r.model.paste(plain: false)
		#expect(r.log == ["paste \(Fixtures.mixed[0].id) plain=false", "closeStart", "sendPaste"])
		#expect(!r.model.cardsMounted)
	}

	@Test func pasteWithoutAccessibilityKeepsTheStripOpenWithAToast() async {
		let r = StripRig()
		r.pasteResult = .accessibilityRequired
		await r.model.paste(plain: true)
		#expect(r.closeStarts == 0)
		#expect(r.model.toast == .accessibilityRequired)
		r.model.openAccessibilitySettings()
		#expect(r.log.last == "openAX")
	}

	@Test func commandNumberPastesByPosition() async {
		let r = StripRig()
		await r.model.paste(position: 3, plain: true)
		#expect(r.log.first == "paste \(Fixtures.mixed[2].id) plain=true")
		let none = StripRig()
		await none.model.paste(position: 10, plain: false)
		#expect(none.log.isEmpty)
	}

	@Test func holdingCommandShowsBadgesOneThroughNine() {
		let r = StripRig()
		#expect(r.model.badge(for: Fixtures.mixed[0].id) == nil)
		r.model.commandHeld = true
		#expect(r.model.badge(for: Fixtures.mixed[0].id) == 1)
		#expect(r.model.badge(for: Fixtures.mixed[8].id) == 9)
	}

	@Test func clickSelectsAndMenuActionsDispatch() async {
		let r = StripRig()
		r.model.select(Fixtures.mixed[3].id)
		#expect(r.model.selectedID == Fixtures.mixed[3].id)
		await r.model.perform(.copy, id: Fixtures.mixed[5].id)
		#expect(r.log == ["copy \(Fixtures.mixed[5].id)"])
		#expect(r.model.cardsMounted)
		await r.model.perform(.pastePlain, id: Fixtures.mixed[6].id)
		#expect(r.log.contains("paste \(Fixtures.mixed[6].id) plain=true"))
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
