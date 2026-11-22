import Testing
import Foundation
import CopiaCore
@testable import CopiaStore

@Suite struct StorePinTests {
	@Test func populatedLegacySchemaMigratesInPlaceAndReopensTwice() async throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir.appendingPathComponent("blobs"), withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("legacy note"), key = draft.contentKey
		try ClipStore.encode(draft.items).write(to: dir.appendingPathComponent("blobs/\(key).plist"))
		try editSQL(dir, """
			CREATE TABLE clips (
				id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, preview_text TEXT NOT NULL,
				is_code INTEGER NOT NULL, source_bundle TEXT, source_name TEXT,
				first_copied REAL NOT NULL, last_copied REAL NOT NULL, copy_count INTEGER NOT NULL,
				byte_size INTEGER NOT NULL, meta TEXT NOT NULL, color_hex TEXT, url TEXT, file_names TEXT NOT NULL,
				preview_state TEXT NOT NULL, generation INTEGER NOT NULL);
			CREATE VIRTUAL TABLE clips_fts USING fts5(id UNINDEXED, title, preview_text, tokenize='trigram');
			CREATE TABLE meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
			INSERT INTO clips VALUES ('\(key)','text','legacy note','find me',0,NULL,'Original',1,2,3,4,'meta',NULL,NULL,'','ok',17);
			INSERT INTO clips_fts SELECT id,title,preview_text FROM clips;
			INSERT INTO meta VALUES ('generation',17);
			""")
		let root = try sqlTextRows(dir, "SELECT rootpage FROM sqlite_master WHERE name='clips'")
		let layout = "SELECT cid,name,type,\"notnull\",coalesce(dflt_value,''),pk FROM pragma_table_info('clips') ORDER BY cid"
		// The original snapshot streamed in index order; do not sort all payload metadata to display pins.
		let orderPlan = "EXPLAIN QUERY PLAN SELECT * FROM clips ORDER BY is_pinned DESC,last_copied DESC,id"
		let legacy = try sqlTextRows(dir, layout)
		try #require(legacy.count == 17)
		let expected = legacy + [["17", "is_pinned", "INTEGER", "1", "0", "0"]]
		let (fresh, freshDir) = try tempStore(); defer { try? FileManager.default.removeItem(at: freshDir) }
		#expect(try sqlTextRows(freshDir, layout) == expected)
		#expect(try await fresh.recent().isEmpty)
		#expect(try sqlTextRows(freshDir, orderPlan).allSatisfy { $0.last?.contains("TEMP B-TREE") == false })
		for _ in 0..<2 {
			let store = try ClipStore(directory: dir)
			try #require(try sqlTextRows(dir, layout) == expected)
			#expect(try sqlTextRows(dir, orderPlan).allSatisfy { $0.last?.contains("TEMP B-TREE") == false })
			#expect(try sqlTextRows(dir, "SELECT rootpage FROM sqlite_master WHERE name='clips'") == root)
			#expect(try sqlTextRows(dir, "SELECT is_pinned, generation, copy_count, source_name FROM clips") == [["0", "17", "3", "Original"]])
			#expect(try sqlTextRows(dir, "SELECT value FROM meta WHERE key='generation'") == [["17"]])
			#expect(try await store.search("find me") == [key])
			#expect(try await store.items(for: key) == draft.items)
		}
	}

	@Test func pinChangesOnlyMetadataAndSurvivesRecopyAndUndo() async throws {
		let display = Clip(id: UUID(), kind: .text, text: "display", timestamp: .now)
		#expect(!display.isPinned)
		#expect(Clip(id: display.id, kind: .text, text: display.text, timestamp: display.timestamp, isPinned: true).isPinned)
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (a, _) = try await store.insert(text("note"))
		#expect(!a.isPinned)
		try await store.setPinned(a.key, to: true)
		var pinned = a; pinned.isPinned = true
		#expect(try await store.fetch(a.key) == pinned)
		let (again, isNew) = try await store.insert(text("note", at: 500))
		#expect(!isNew && again.isPinned && again.copyCount == 2 && again.generation == a.generation)
		#expect(try await store.items(for: a.key) == text("note").items)
		let deleted = try #require(try await store.delete(a.key))
		#expect(try await store.restore(deleted).isPinned)
		#expect(try await store.fetch(a.key)?.isPinned == true)
		try await store.setPinned(a.key, to: false)
		#expect(try await store.fetch(a.key)?.isPinned == false)
		await #expect(throws: StoreError.self) { try await store.setPinned("missing", to: true) }
	}

	@Test func recopyAfterReopenPreservesPinAndIncrementsExistingCount() async throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("persistent pin", at: 10), key = draft.contentKey
		let original: StoredClip
		do {
			let store = try ClipStore(directory: dir)
			(original, _) = try await store.insert(draft)
			try await store.setPinned(key, to: true)
		}
		let reopened = try ClipStore(directory: dir)
		let pinned = try #require(try await reopened.fetch(key))
		#expect(pinned.isPinned && pinned.copyCount == original.copyCount)
		let recopy = text("persistent pin", at: 20)
		let (again, isNew) = try await reopened.insert(recopy)
		#expect(!isNew && again.key == key && again.isPinned && again.copyCount == original.copyCount + 1)
		#expect(again.generation == original.generation && again.firstCopied == draft.copiedAt && again.lastCopied == recopy.copiedAt)
		#expect(try await reopened.recent() == [again])
	}

	@Test func unpinningAnOldClipMakesItsRowFTSBlobAndThumbnailEligibleForPrune() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("https://example.com/unpin", at: 100), cutoff = Date(timeIntervalSince1970: 101)
		let (clip, _) = try await store.insert(draft)
		let key = clip.key, image = Data([1, 0, 3])
		try await store.setPreview(key: key, generation: clip.generation, state: .ok, image: image)
		try await store.setPinned(key, to: true)
		#expect(try await store.prune(before: cutoff) == 0)
		#expect(try await store.ftsKeys() == [key])
		#expect(try await store.items(for: key) == draft.items)
		let thumb = try #require(await store.thumbnail(for: key))
		#expect(try Data(contentsOf: thumb) == image)
		try await store.setPinned(key, to: false)
		#expect(try await store.prune(before: cutoff) == 1)
		#expect(try await store.fetch(key) == nil)
		#expect(try await store.ftsKeys().isEmpty)
		#expect(try dataFiles(dir).isEmpty)
	}

	@Test func snapshotAndAllSearchPathsUseTheSameStablePinOrder() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let drafts = [text("match A", at: 10), text("match B", at: 10), text("match C", at: 20), text("match D", at: 30)]
		for draft in drafts.sorted(by: { $0.contentKey > $1.contentKey }) { try await store.insert(draft) }
		for draft in drafts.prefix(3) { try await store.setPinned(draft.contentKey, to: true) }
		let expected = [drafts[2].contentKey] + drafts.prefix(2).map(\.contentKey).sorted() + [drafts[3].contentKey]
		#expect(try await store.snapshot().map(\.clip.key) == expected)
		for query in ["", "ma", "match"] { #expect(try await store.search(query) == expected) }
	}

	@Test func retentionPreservesPinnedRowsFTSAndFilesButNotCorruptRowsOrErasedHistory() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (pin, _) = try await store.insert(text("https://example.com/pinned", at: 1))
		let (corrupt, _) = try await store.insert(text("corrupt pin", at: 1))
		let (old, _) = try await store.insert(text("expired", at: 1))
		let (boundary, _) = try await store.insert(text("boundary", at: 2))
		try await store.setPreview(key: pin.key, generation: pin.generation, state: .ok, image: Data([7]))
		for key in [pin.key, corrupt.key] { try await store.setPinned(key, to: true) }
		#expect(try await store.prune(before: Date(timeIntervalSince1970: 2)) == 1)
		#expect(try await store.fetch(old.key) == nil)
		#expect(Set(try await store.ftsKeys()) == [pin.key, corrupt.key, boundary.key])
		#expect(try await store.items(for: pin.key) == text("https://example.com/pinned").items)
		#expect(try Data(contentsOf: dir.appendingPathComponent("thumbs/\(pin.key).png")) == Data([7]))
		try FileManager.default.removeItem(at: dir.appendingPathComponent("blobs/\(corrupt.key).plist"))
		try await store.sweep()
		#expect(try await store.fetch(corrupt.key) == nil)
		#expect(Set(try await store.ftsKeys()) == [pin.key, boundary.key])
		try await store.eraseAll()
		#expect(try await store.recent().isEmpty)
		#expect(try await store.ftsKeys().isEmpty)
		#expect(fileCount(dir, "blobs") + fileCount(dir, "thumbs") + fileCount(dir, "trash") == 0)
	}
}
