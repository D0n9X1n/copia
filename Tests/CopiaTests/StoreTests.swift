import Testing
import Foundation
import CopiaCore
@testable import CopiaStore

/// Fails the next matching file operation once.
final class FaultyFiles: FileOps, @unchecked Sendable {
	let live = LiveFileOps()
	var failMoveContaining: String?
	var failWriteContaining: String?
	var failRemoveContaining: String?
	func write(_ data: Data, to url: URL) throws {
		if let f = failWriteContaining, url.path.contains(f) { failWriteContaining = nil; throw CocoaError(.fileWriteUnknown) }
		try live.write(data, to: url)
	}
	func move(_ from: URL, to: URL) throws {
		if let f = failMoveContaining, from.path.contains(f) || to.path.contains(f) { failMoveContaining = nil; throw CocoaError(.fileWriteUnknown) }
		try live.move(from, to: to)
	}
	func remove(_ url: URL) throws {
		if let f = failRemoveContaining, url.path.contains(f) { failRemoveContaining = nil; throw CocoaError(.fileWriteUnknown) }
		try live.remove(url)
	}
	func exists(_ url: URL) -> Bool { live.exists(url) }
	func list(_ directory: URL) -> [URL] { live.list(directory) }
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
		#expect(try await store.fetch(clip.key) != nil)
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

	@Test func faultDuringDeleteIsCleanedBySweep() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("orphan"))
		faulty.failMoveContaining = "blobs"
		faulty.failRemoveContaining = "blobs"
		_ = try await store.delete(clip.key)
		#expect(try await store.fetch(clip.key) == nil)
		#expect(fileCount(dir, "blobs") == 1)
		try await store.sweep()
		#expect(fileCount(dir, "blobs") == 0)
	}

	@Test func aFailedMoveToTrashStillLeavesNoFilesBehind() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("orphan"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		faulty.failMoveContaining = "thumbs"
		_ = try await store.delete(clip.key)
		#expect(try await store.fetch(clip.key) == nil)
		#expect(fileCount(dir, "blobs") == 0)
		#expect(fileCount(dir, "thumbs") == 0)
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
		try await store.insert(text("b2"))
		_ = try await store.delete(clip.key)
		try await store.eraseAll()
		#expect(try await store.recent().isEmpty)
		#expect(fileCount(dir, "blobs") + fileCount(dir, "thumbs") + fileCount(dir, "trash") == 0)
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
