import Testing
import Foundation
import CopiaCore
@testable import CopiaStore

/// Fails the next matching file operation once.
final class FaultyFiles: FileOps, @unchecked Sendable {
	let live = LiveFileOps()
	var failMoveContaining: String?
	/// Matches only the source path, so a rollback move out of trash can fail while the move into trash succeeds.
	var failMoveFromContaining: String?
	var failWriteContaining: String?
	var failRemoveContaining: String?
	func write(_ data: Data, to url: URL) throws {
		if let f = failWriteContaining, url.path.contains(f) { failWriteContaining = nil; throw CocoaError(.fileWriteUnknown) }
		try live.write(data, to: url)
	}
	func move(_ from: URL, to: URL) throws {
		if let f = failMoveContaining, from.path.contains(f) || to.path.contains(f) { failMoveContaining = nil; throw CocoaError(.fileWriteUnknown) }
		if let f = failMoveFromContaining, from.path.contains(f) { failMoveFromContaining = nil; throw CocoaError(.fileWriteUnknown) }
		try live.move(from, to: to)
	}
	func remove(_ url: URL) throws {
		if let f = failRemoveContaining, url.path.contains(f) { failRemoveContaining = nil; throw CocoaError(.fileWriteUnknown) }
		try live.remove(url)
	}
	func exists(_ url: URL) -> Bool { live.exists(url) }
	func list(_ directory: URL) throws -> [URL] { try live.list(directory) }
}

private func text(_ s: String, at t: TimeInterval = 1_800_000_000) -> ClipDraft {
	ClipDraft(items: [PasteboardItemData([(PasteboardTypes.string, Data(s.utf8))])], copiedAt: Date(timeIntervalSince1970: t))
}

private func tempStore(files: FileOps = LiveFileOps()) throws -> (ClipStore, URL) {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-store-\(UUID().uuidString)")
	return (try ClipStore(directory: dir, files: files), dir)
}

private func fileCount(_ dir: URL, _ sub: String) -> Int {
	(try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path).count) ?? 0
}

@Suite struct StoreTests {
	@Test func insertsAndRoundTripsEveryRepresentationInOrder() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let files = (1...300).map { PasteboardItemData([(PasteboardTypes.fileURL, Data("file:///tmp/f\($0).txt".utf8))]) }
		let mixed = PasteboardItemData([(PasteboardTypes.string, Data("hi".utf8)), (PasteboardTypes.rtf, Data("{\\rtf1 hi}".utf8)),
			(PasteboardTypes.html, Data("<b>hi</b>".utf8)), (PasteboardTypes.png, Data([0x89, 0x50, 0x4E, 0x47]))])
		let draft = ClipDraft(items: [mixed] + files, copiedAt: .now)
		let (clip, isNew) = try await store.insert(draft)
		#expect(isNew)
		let back = try await store.items(for: clip.key)
		#expect(back == draft.items)
		#expect(back.count == 301)
	}

	@Test func recopyMovesToFrontAndKeepsPayload() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		try await store.insert(text("first", at: 1))
		try await store.insert(text("second", at: 2))
		let (again, isNew) = try await store.insert(text("first", at: 3))
		#expect(!isNew)
		#expect(again.copyCount == 2)
		#expect(try await store.recent().map(\.title) == ["first", "second"])
	}

	@Test func deleteRemovesRowFtsBlobAndThumb() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("delete me"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1, 2, 3]))
		#expect(fileCount(dir, "thumbs") == 1)
		_ = try await store.delete(clip.key)
		#expect(try await store.fetch(clip.key) == nil)
		#expect(try await store.search("delete").isEmpty)
		#expect(fileCount(dir, "blobs") == 0)
		#expect(fileCount(dir, "thumbs") == 0)
	}

	@Test func undoRestoresAndInvalidatesOnEmptyTrash() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("keep me"))
		let deleted = try #require(try await store.delete(clip.key))
		try await store.restore(deleted)
		#expect(try await store.fetch(clip.key)?.previewState == .ok)
		#expect(try await store.search("keep me") == [clip.key])
		let again = try #require(try await store.delete(clip.key))
		await store.emptyTrash()
		#expect(fileCount(dir, "trash") == 0)
		await #expect(throws: StoreError.missingBlob) { try await store.restore(again) }
		#expect(try await store.fetch(clip.key) == nil)
	}

	@Test func restoreAfterRecopyIsRefused() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("dup"))
		let deleted = try #require(try await store.delete(clip.key))
		try await store.insert(text("dup"))
		await #expect(throws: StoreError.alreadyExists) { try await store.restore(deleted) }
	}

	@Test func stalePreviewWritesNothingAfterDeleteOrRecopy() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("x"))
		_ = try await store.delete(clip.key)
		#expect(try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([9])) == false)
		let (fresh, _) = try await store.insert(text("x"))
		#expect(fresh.generation != clip.generation)
		#expect(try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([9])) == false)
		#expect(fileCount(dir, "thumbs") == 0)
		#expect(try await store.setPreview(key: fresh.key, generation: fresh.generation, state: .ok, title: "Title", image: Data([9])))
		#expect(try await store.search("Title") == [fresh.key])
	}

	/// The row, its FTS entry, its blob and its thumbnail are all in place, and nothing is in trash.
	private func expectWhole(_ store: ClipStore, _ dir: URL, _ clip: StoredClip, sourceLocation: SourceLocation = #_sourceLocation) async throws {
		#expect(try await store.fetch(clip.key) != nil, sourceLocation: sourceLocation)
		#expect(try await store.ftsKeys() == [clip.key], sourceLocation: sourceLocation)
		#expect(try await store.items(for: clip.key).count == 1, sourceLocation: sourceLocation)
		#expect(await store.thumbnail(for: clip.key) != nil, sourceLocation: sourceLocation)
		#expect(fileCount(dir, "trash") == 0, sourceLocation: sourceLocation)
	}

	/// A delete whose blob cannot reach trash changes nothing, in-session and after the launch sweep; a retry then succeeds.
	@Test func faultDuringDeleteKeepsRowFtsAndFilesTogether() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("orphan"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		faulty.failMoveContaining = "blobs"
		faulty.failRemoveContaining = "blobs"
		await #expect(throws: (any Error).self) { try await store.delete(clip.key) }
		try await expectWhole(store, dir, clip)
		try await store.sweep()
		try await expectWhole(store, dir, clip)
		_ = try #require(try await store.delete(clip.key))
		#expect(try await store.fetch(clip.key) == nil)
		#expect(try await store.ftsKeys().isEmpty)
		#expect(fileCount(dir, "blobs") + fileCount(dir, "thumbs") == 0)
		#expect(fileCount(dir, "trash") == 2)
	}

	/// The blob already reached trash when the thumbnail's move fails: the blob goes back and the clip stays whole.
	@Test func aFailedThumbnailMoveToTrashKeepsTheWholeClip() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("orphan"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		faulty.failMoveContaining = "thumbs"
		await #expect(throws: (any Error).self) { try await store.delete(clip.key) }
		try await expectWhole(store, dir, clip)
		try await store.sweep()
		try await expectWhole(store, dir, clip)
	}

	/// The files reached trash but the row could not be deleted: the files go back, so the sweep never strands the row.
	@Test func aFailedRowDeleteMovesTheFilesBack() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("orphan"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		await store.failNextWrite()
		await #expect(throws: StoreError.self) { try await store.delete(clip.key) }
		try await expectWhole(store, dir, clip)
		try await store.sweep()
		try await expectWhole(store, dir, clip)
	}

	/// The thumbnail fails to reach trash and the blob cannot move back: the delete throws, and the blob sits in trash
	/// under a row that is still live.
	private func strandBlobInTrash(_ store: ClipStore, _ dir: URL, _ faulty: FaultyFiles) async throws -> StoredClip {
		let (clip, _) = try await store.insert(text("keep me"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		faulty.failMoveContaining = "thumbs/"
		faulty.failMoveFromContaining = "trash/\(clip.key).plist"
		await #expect(throws: (any Error).self) { try await store.delete(clip.key) }
		#expect(try await store.fetch(clip.key) != nil)
		#expect(fileCount(dir, "blobs") == 0 && fileCount(dir, "trash") == 1)
		return clip
	}

	/// Every pass that empties or cleans files first moves a live row's stranded blob home, so the row stays whole.
	@Test(arguments: ["emptyTrash", "sweep", "removeOrphans"])
	func aBlobStrandedByAFailedDeleteRollbackGoesHomeBeforeCleanup(pass: String) async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let clip = try await strandBlobInTrash(store, dir, faulty)
		switch pass {
		case "emptyTrash": await store.emptyTrash()
		case "sweep": try await store.sweep()
		default: try await store.removeOrphans()
		}
		try await expectWhole(store, dir, clip)
		try await store.sweep()
		try await expectWhole(store, dir, clip)
	}

	/// The row delete fails and the thumbnail cannot move back: emptying trash moves it home instead of removing it.
	@Test func aThumbnailStrandedByAFailedDeleteRollbackGoesHome() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("keep me"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		await store.failNextWrite()
		faulty.failMoveFromContaining = "trash/\(clip.key).png"
		await #expect(throws: StoreError.self) { try await store.delete(clip.key) }
		#expect(fileCount(dir, "thumbs") == 0 && fileCount(dir, "trash") == 1)
		await store.emptyTrash()
		try await expectWhole(store, dir, clip)
	}

	/// If moving the stranded blob home fails too, it stays in trash and its row stays live; a later pass recovers it.
	@Test func aStrandedBlobWhoseMoveHomeFailsIsKeptNotRemoved() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let clip = try await strandBlobInTrash(store, dir, faulty)
		faulty.failMoveContaining = "trash/\(clip.key).plist"
		await store.emptyTrash()
		#expect(try await store.fetch(clip.key) != nil)
		#expect(fileCount(dir, "trash") == 1)
		faulty.failMoveContaining = "trash/\(clip.key).plist"
		try await store.sweep()
		#expect(try await store.fetch(clip.key) != nil)
		#expect(fileCount(dir, "trash") == 1)
		try await store.sweep()
		try await expectWhole(store, dir, clip)
	}

	/// Undo after its trashed thumbnail was lost brings back a whole clip that asks for a new preview,
	/// never a final preview state without its image.
	@Test func restoreWithoutItsTrashedThumbnailAsksForANewPreview() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let link = text("https://example.com/post")
		let (clip, _) = try await store.insert(link)
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Saved", image: Data([1]))
		let deleted = try #require(try await store.delete(clip.key))
		faulty.failRemoveContaining = "trash/\(clip.key).plist"
		await store.emptyTrash()
		#expect(fileCount(dir, "trash") == 1)
		try await store.restore(deleted)
		let back = try #require(try await store.fetch(clip.key))
		#expect(back.previewState == .pending)
		#expect(try await store.pending().map(\.key) == [clip.key])
		#expect(try await store.items(for: clip.key) == link.items)
		#expect(try await store.ftsKeys() == [clip.key])
		#expect(await store.thumbnail(for: clip.key) == nil)
		#expect(fileCount(dir, "trash") == 0)
	}

	@Test func recopyingADeletedItemEmptiesItsTrash() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("again"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		_ = try await store.delete(clip.key)
		#expect(fileCount(dir, "trash") == 2)
		try await store.insert(text("again"))
		#expect(fileCount(dir, "trash") == 0)
		#expect(fileCount(dir, "blobs") == 1)
	}

	@Test func recentReturnsEveryClip() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		try await store.seedRows((0..<5_001).map { i in
			StoredClip(key: "k\(i)", kind: .text, title: "clip \(i)", previewText: "", isCode: false, sourceBundle: nil, sourceName: nil,
				firstCopied: Date(timeIntervalSince1970: Double(i)), lastCopied: Date(timeIntervalSince1970: Double(i)), copyCount: 1,
				byteSize: 1, meta: "", colorHex: nil, url: nil, fileNames: [], previewState: .ok, generation: i)
		})
		let all = try await store.recent()
		#expect(all.count == 5_001)
		#expect(all.last?.title == "clip 0")
	}

	@Test func aColorRoundTrips() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("#ff6a3d"))
		let stored = try #require(try await store.fetch(clip.key))
		#expect(stored.kind == .color)
		#expect(stored.colorHex == "#FF6A3D")
		#expect(try await store.items(for: clip.key).first?.data(for: PasteboardTypes.string) == Data("#ff6a3d".utf8))
	}

	@Test func faultDuringRestoreRollsBackCompletely() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("roll"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		let deleted = try #require(try await store.delete(clip.key))
		faulty.failMoveContaining = "trash/\(clip.key).png"
		await #expect(throws: (any Error).self) { try await store.restore(deleted) }
		#expect(try await store.fetch(clip.key) == nil)
		#expect(try await store.search("roll").isEmpty)
		#expect(fileCount(dir, "blobs") == 0)
		#expect(fileCount(dir, "trash") == 2)
		try await store.restore(deleted)
		#expect(try await store.fetch(clip.key) != nil)
	}

	@Test func sweepDropsRowsWithMissingBlobsAndTheirFts() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("lost blob"))
		try FileManager.default.removeItem(at: dir.appendingPathComponent("blobs/\(clip.key).plist"))
		try await store.sweep()
		#expect(try await store.fetch(clip.key) == nil)
		#expect(try await store.search("lost").isEmpty)
	}

	@Test func pruneRemovesExpiredRowsAndFiles() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		try await store.insert(text("old", at: 100))
		try await store.insert(text("new", at: 1_000))
		#expect(try await store.prune(before: Date(timeIntervalSince1970: 500)) == 1)
		#expect(try await store.recent().map(\.title) == ["new"])
		#expect(fileCount(dir, "blobs") == 1)
		#expect(try await store.search("old").isEmpty)
	}

	@Test func eraseRemovesEverything() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("a1"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		let (other, _) = try await store.insert(text("b2"))
		try await store.setPreview(key: other.key, generation: other.generation, state: .ok, image: Data([2]))
		_ = try await store.delete(clip.key)
		#expect(fileCount(dir, "thumbs") == 1)
		#expect(fileCount(dir, "trash") == 2)
		try await store.eraseAll()
		#expect(try await store.recent().isEmpty)
		#expect(try await store.ftsKeys().isEmpty)
		#expect(fileCount(dir, "blobs") + fileCount(dir, "thumbs") + fileCount(dir, "trash") == 0)
	}

	/// Checked in the FTS table itself: search joins on the clips table, so it would hide a leftover entry.
	@Test func deletePruneAndEraseLeaveNoFtsEntry() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (deleted, _) = try await store.insert(text("deleted one", at: 1_000))
		let (expired, _) = try await store.insert(text("expired one", at: 100))
		let (kept, _) = try await store.insert(text("kept one", at: 1_000))
		#expect(Set(try await store.ftsKeys()) == [deleted.key, expired.key, kept.key])
		_ = try await store.delete(deleted.key)
		#expect(Set(try await store.ftsKeys()) == [expired.key, kept.key])
		try await store.prune(before: Date(timeIntervalSince1970: 500))
		#expect(try await store.ftsKeys() == [kept.key])
		try await store.eraseAll()
		#expect(try await store.ftsKeys().isEmpty)
	}

	@Test func pruneRemovesAnExpiredClipsThumbnail() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (old, _) = try await store.insert(text("old", at: 100))
		try await store.setPreview(key: old.key, generation: old.generation, state: .ok, image: Data([1]))
		let (new, _) = try await store.insert(text("new", at: 1_000))
		try await store.setPreview(key: new.key, generation: new.generation, state: .ok, image: Data([2]))
		#expect(fileCount(dir, "thumbs") == 2)
		#expect(try await store.prune(before: Date(timeIntervalSince1970: 500)) == 1)
		#expect(await store.thumbnail(for: old.key) == nil)
		#expect(await store.thumbnail(for: new.key) != nil)
		#expect(fileCount(dir, "thumbs") == 1)
		#expect(fileCount(dir, "blobs") == 1)
	}

	/// A read that fails part-way must not look like an empty history: launch cleanup would then delete every file.
	@Test func aFailedReadStopsSweepBeforeItRemovesAnything() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("keep me"))
		await store.failNextStep()
		await #expect(throws: StoreError.self) { try await store.sweep() }
		#expect(fileCount(dir, "blobs") == 1)
		#expect(try await store.fetch(clip.key)?.title == "keep me")
		await store.failNextStep()
		await #expect(throws: StoreError.self) { try await store.recent() }
	}

	/// An unreadable blobs folder is not an empty one: sweep must stop, not drop rows whose files it cannot see.
	@Test func sweepKeepsRowsWhenTheBlobsFolderCannotBeRead() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("still here"))
		let blobs = dir.appendingPathComponent("blobs").path
		try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blobs)
		await #expect(throws: (any Error).self) { try await store.sweep() }
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobs)
		#expect(try await store.fetch(clip.key)?.title == "still here")
		try await store.sweep()
		#expect(try await store.items(for: clip.key).count == 1)
	}

	/// Erase that cannot even list a folder must say so, not report success.
	@Test func eraseReportsAFolderItCouldNotRead() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		try await store.insert(text("secret"))
		let blobs = dir.appendingPathComponent("blobs").path
		try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blobs)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobs) }
		await #expect(throws: StoreError.self) { try await store.eraseAll() }
	}

	/// A folder that lists but cannot be searched must not make a failed removal look like a file already gone.
	@Test func eraseReportsFilesInAFolderItCannotSearch() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		try await store.insert(text("secret"))
		let blobs = dir.appendingPathComponent("blobs").path
		try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: blobs)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobs) }
		await #expect(throws: StoreError.self) { try await store.eraseAll() }
	}

	/// Removing a file the folder will not let us reach is a failure, not "already gone".
	@Test func liveRemoveReportsAFileItCannotReach() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-rm-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
		let file = dir.appendingPathComponent("a.plist")
		try Data("x".utf8).write(to: file)
		try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: dir.path)
		#expect(throws: (any Error).self) { try LiveFileOps().remove(file) }
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
		try LiveFileOps().remove(dir.appendingPathComponent("never-existed"))
	}

	/// A recopy that fails to save must not have thrown away the undo copy first.
	@Test func aFailedRecopyKeepsTheUndo() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("again"))
		let gone = try #require(try await store.delete(clip.key))
		files.failWriteContaining = "blobs"
		await #expect(throws: (any Error).self) { try await store.insert(text("again")) }
		try await store.restore(gone)
		#expect(try await store.fetch(clip.key)?.title == "again")
	}

	/// Files left by a failed prune or erase have no row; the hourly pass removes them and leaves undo copies alone.
	@Test func removeOrphansClearsLeftoversButKeepsTrash() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (stuck, _) = try await store.insert(text("stuck", at: 100))
		let (undoable, _) = try await store.insert(text("undoable"))
		files.failRemoveContaining = stuck.key
		#expect(try await store.prune(before: Date(timeIntervalSince1970: 500)) == 1)
		_ = try await store.delete(undoable.key)
		#expect(fileCount(dir, "blobs") == 1)
		try await store.removeOrphans()
		#expect(fileCount(dir, "blobs") == 0)
		#expect(fileCount(dir, "trash") == 1)
	}

	/// Erase removes everything it can, then reports a file it could not remove instead of claiming success.
	@Test func eraseReportsAFileItCouldNotRemove() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (stuck, _) = try await store.insert(text("stuck"))
		try await store.insert(text("other"))
		files.failRemoveContaining = stuck.key
		await #expect(throws: StoreError.filesLeft(1)) { try await store.eraseAll() }
		#expect(try await store.recent().isEmpty)
		#expect(fileCount(dir, "blobs") == 1)
	}

	@Test func searchHandlesShortQueriesAndLiteralSpecialCharacters() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (a, _) = try await store.insert(text("50% off_today \"quoted\""))
		let (b, _) = try await store.insert(text("plain words here"))
		#expect(try await store.search("p") .contains(b.key))
		#expect(try await store.search("of") == [a.key])
		#expect(try await store.search("wor") == [b.key])
		#expect(try await store.search("%") == [a.key])
		#expect(try await store.search("_t") == [a.key])
		#expect(try await store.search("\"quoted\"") == [a.key])
		#expect(try await store.search("zz%").isEmpty)
	}
}

extension ClipStore {
	/// Rows only, in one transaction: enough for read-path tests without thousands of blob writes.
	func seedRows(_ clips: [StoredClip]) throws {
		try transaction { for clip in clips { try insertRow(clip) } }
	}
}
