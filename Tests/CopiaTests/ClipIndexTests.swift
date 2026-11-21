import Testing
import Foundation
@testable import CopiaApp

@MainActor
@Suite struct ClipIndexTests {
	let a = UUID(), b = UUID()

	@Test func aSnapshotFetchedBeforeADeleteIsRejected() {
		var index = ClipIndex<String>()
		index.apply([a: "ka", b: "kb"], fetchedAt: index.mutations)
		let before = index.mutations
		index.noteDeleted(a, "trashed a")
		let applied = index.apply([a: "ka", b: "kb"], fetchedAt: before)
		#expect(!applied)
		#expect(index.deletion(for: a) == "trashed a")
		#expect(index.keys[a] == nil)
	}

	@Test func aRecopyOfADeletedClipEndsItsUndo() {
		var index = ClipIndex<String>()
		index.noteDeleted(a, "trashed a")
		let applied = index.apply([a: "ka"], fetchedAt: index.mutations)
		#expect(applied)
		#expect(index.deletion(for: a) == nil)
	}

	@Test func restoringPutsTheKeyBackBeforeAnyReload() {
		var index = ClipIndex<String>()
		index.apply([a: "ka"], fetchedAt: index.mutations)
		index.noteDeleted(a, "trashed a")
		let applied = index.apply([:], fetchedAt: index.mutations)
		#expect(applied)
		index.noteRestored(a, key: "ka")
		#expect(index.keys[a] == "ka")
		#expect(index.deletion(for: a) == nil)
	}

	@Test func closingForgetsDeletionsWithoutInvalidatingReloads() {
		var index = ClipIndex<String>()
		index.noteDeleted(a, "trashed a")
		let before = index.mutations
		index.clearDeletions()
		#expect(index.deletion(for: a) == nil)
		let applied = index.apply([b: "kb"], fetchedAt: before)
		#expect(applied)
	}

	@Test func aSnapshotFetchedBeforeEraseIsRejected() {
		var index = ClipIndex<String>()
		index.apply([a: "ka"], fetchedAt: index.mutations)
		let before = index.mutations
		index.noteErased()
		let applied = index.apply([a: "ka"], fetchedAt: before)
		#expect(!applied)
		#expect(index.keys.isEmpty)
	}
}
