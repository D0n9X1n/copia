import Testing
import Foundation
@testable import CopiaApp

@MainActor
@Suite struct ClipIndexTests {
	let a = UUID(), b = UUID()

	@Test func recopyInvalidatesAllMembersOfOneGroup() {
		var index = ClipIndex()
		let token = UUID(), other = UUID(), c = UUID()
		index.noteDeleted([a, b], token: token)
		index.noteDeleted([c], token: other)
		let beforePin = index.mutations
		index.noteChanged()
		let appliedStale = index.apply([a: "old"], fetchedAt: beforePin)
		let appliedRecopy = index.apply([a: "recopy"], fetchedAt: index.mutations)
		#expect(!appliedStale)
		#expect(appliedRecopy)
		#expect(index.takeEndedUndos() == [a, b])
		#expect(!index.canRestore(token))
		#expect(index.canRestore(other))
	}

	@Test func aSnapshotFetchedBeforeADeleteIsRejected() {
		var index = ClipIndex()
		let token = UUID()
		index.apply([a: "ka", b: "kb"], fetchedAt: index.mutations)
		let before = index.mutations
		index.noteDeleted([a], token: token)
		let applied = index.apply([a: "ka", b: "kb"], fetchedAt: before)
		#expect(!applied)
		#expect(index.canRestore(token))
		#expect(index.keys[a] == nil)
	}

	@Test func aRecopyOfADeletedClipEndsItsUndo() {
		var index = ClipIndex()
		let token = UUID()
		index.noteDeleted([a], token: token)
		let applied = index.apply([a: "ka"], fetchedAt: index.mutations)
		#expect(applied)
		#expect(!index.canRestore(token))
		#expect(index.takeEndedUndos() == [a])
		#expect(index.takeEndedUndos().isEmpty)
	}

	@Test func eraseEndsEveryUndo() {
		var index = ClipIndex()
		let token = UUID()
		index.noteDeleted([a], token: token)
		index.noteDeleted([b], token: UUID())
		index.noteErased()
		#expect(index.takeEndedUndos() == [a, b])
	}

	@Test func restoringPutsTheKeyBackBeforeAnyReload() {
		var index = ClipIndex()
		let token = UUID()
		index.apply([a: "ka"], fetchedAt: index.mutations)
		index.noteDeleted([a], token: token)
		let applied = index.apply([:], fetchedAt: index.mutations)
		#expect(applied)
		index.noteRestored(token, keys: [a: "ka"])
		#expect(index.keys[a] == "ka")
		#expect(!index.canRestore(token))
	}

	@Test func closingForgetsDeletionsWithoutInvalidatingReloads() {
		var index = ClipIndex()
		let token = UUID()
		index.noteDeleted([a], token: token)
		let before = index.mutations
		index.clearDeletions()
		#expect(!index.canRestore(token))
		let applied = index.apply([b: "kb"], fetchedAt: before)
		#expect(applied)
	}

	@Test func aSnapshotFetchedBeforeEraseIsRejected() {
		var index = ClipIndex()
		index.apply([a: "ka"], fetchedAt: index.mutations)
		let before = index.mutations
		index.noteErased()
		let applied = index.apply([a: "ka"], fetchedAt: before)
		#expect(!applied)
		#expect(index.keys.isEmpty)
	}
	@Test func expiringOneDeletionDoesNotForgetAnother() {
		var index = ClipIndex()
		let token = UUID()
		let other = UUID()
		index.noteDeleted([a], token: token)
		index.noteDeleted([b], token: other)
		index.forget(token)
		#expect(!index.canRestore(token))
		#expect(index.canRestore(other))
	}

}
