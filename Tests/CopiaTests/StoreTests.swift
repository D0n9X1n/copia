import Testing
import Foundation
import CopiaCore
@testable import CopiaStore

/// Fails the next matching file operation once.
final class FaultyFiles: FileOps, @unchecked Sendable {
	let live = LiveFileOps()
	var listCalls = 0
	var readCalls = 0
	var failCopyContaining: String?
	var failWriteContaining: String?
	var failRemoveContaining: String?
	var failListContaining: String?
	var failListAfter: Int?
	var failAtomicWrite = false
	/// Persistent: matching paths look absent to `exists`, and copying them fails with a permission error, as a file in a
	/// folder without search permission does.
	var hideContaining: String?
	func write(_ data: Data, to url: URL) throws {
		if failAtomicWrite {
			failAtomicWrite = false
			try Data([8]).write(to: url.deletingLastPathComponent().appendingPathComponent(".atomic-leftover"))
			throw CocoaError(.fileWriteUnknown)
		}
		if let f = failWriteContaining, url.path.contains(f) { failWriteContaining = nil; throw CocoaError(.fileWriteUnknown) }
		try live.write(data, to: url)
	}
	func read(_ url: URL) throws -> Data {
		readCalls += 1
		if let f = hideContaining, url.path.contains(f) { throw CocoaError(.fileReadNoPermission) }
		return try Data(contentsOf: url, options: .mappedIfSafe)
	}
	func copy(_ from: URL, to: URL) throws {
		if let f = failCopyContaining, from.path.contains(f) || to.path.contains(f) { failCopyContaining = nil; throw CocoaError(.fileWriteUnknown) }
		if let f = hideContaining, from.path.contains(f) { throw CocoaError(.fileReadNoPermission) }
		try live.copy(from, to: to)
	}
	func remove(_ url: URL) throws {
		if let f = failRemoveContaining, url.path.contains(f), live.exists(url) { failRemoveContaining = nil; throw CocoaError(.fileWriteUnknown) }
		try live.remove(url)
	}
	func exists(_ url: URL) -> Bool {
		if let f = hideContaining, url.path.contains(f) { return false }
		return live.exists(url)
	}
	func list(_ directory: URL) throws -> [URL] {
		listCalls += 1
		if let left = failListAfter {
			if left == 0 { throw CocoaError(.fileReadNoPermission) }
			failListAfter = left - 1
		}
		if let f = failListContaining, directory.path.contains(f) { throw CocoaError(.fileReadNoPermission) }
		return try live.list(directory)
	}
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
	@Test(arguments: [false, true])
	func ordinaryCloseDoesNotScanHistoryAndKeepsLaterTokens(failUnlink: Bool) async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		for i in 0..<1_000 { try await store.insert(text("history \(i)")) }
		let (first, _) = try await store.insert(text("close first"))
		let (second, _) = try await store.insert(text("close later"))
		let expired = try #require(try await store.delete(first.key))
		let later = try #require(try await store.delete(second.key))
		#expect(await store.cleanupPending == false)
		files.listCalls = 0
		await store.resetReadCounts()
		if failUnlink { files.failRemoveContaining = first.key }
		await store.emptyTrash(through: expired.issuedSequence)
		#expect(files.listCalls == 0)
		#expect(await store.readRowCount <= 1)
		#expect(await store.readStatementCount <= 1)
		#expect(await store.cleanupPending == failUnlink)
		#expect(fileCount(dir, "trash") == (failUnlink ? 2 : 1))
		await #expect(throws: StoreError.undoExpired) { try await store.restore(expired) }
		if failUnlink {
			files.failListContaining = "thumbs"
			await store.emptyTrash(through: expired.issuedSequence)
			#expect(fileCount(dir, "trash") == 2)
			#expect(await store.cleanupPending)
			files.failListContaining = nil
			await store.emptyTrash(through: expired.issuedSequence)
			#expect(fileCount(dir, "trash") == 1)
			#expect(await store.cleanupPending == false)
		}
		try await store.restore(later)
		#expect(try await store.items(for: second.key) == text("close later").items)
		if failUnlink {
			try await store.removeOrphans()
			#expect(await store.cleanupPending == false)
		} else {
			files.listCalls = 0
			await store.resetReadCounts()
			await store.emptyTrash()
			#expect(files.listCalls == 0)
			#expect(await store.readStatementCount == 0)
		}
	}

	@Test(arguments: [false, true])
	func hourlyCleanupUsesOneInventoryAndRetainsFailedPaths(failUnlink: Bool) async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("owned"))
		let deleted = try #require(try await store.delete(clip.key))
		try Data([1]).write(to: dir.appendingPathComponent("blobs/orphan.plist"))
		try Data([2]).write(to: dir.appendingPathComponent("thumbs/.atomic-leftover"))
		if failUnlink { files.failRemoveContaining = "orphan.plist" }
		files.listCalls = 0
		await store.resetReadCounts()
		try await store.removeOrphans()
		#expect(files.listCalls == 3)
		#expect(await store.readStatementCount == 1)
		#expect(await store.cleanupPending == failUnlink)
		#expect(fileCount(dir, "blobs") == (failUnlink ? 1 : 0))
		#expect(fileCount(dir, "thumbs") == 0 && fileCount(dir, "trash") == 1)
		try await store.restore(deleted)
		if failUnlink {
			files.listCalls = 0
			try await store.removeOrphans()
			#expect(files.listCalls == 3)
			#expect(await store.cleanupPending == false)
		}
	}

	@Test func legacyRecoveryNeedsOnlyOneAdditionalInventory() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let clip = try await strandBlobInTrash(store, dir, files)
		files.listCalls = 0
		try await store.removeOrphans()
		#expect(files.listCalls == 6)
		#expect(await store.cleanupPending == false)
		try await expectWhole(store, dir, clip)
	}

	@Test(arguments: ["insert", "preview", "delete", "restore"])
	func confirmedSQLRollbackWithCompleteFilesDoesNotInventCleanupDebt(op: String) async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, deleted) = try await writeFixture(op, store)
		let rows = try await store.recent(), before = try dataFiles(dir)
		#expect(await store.cleanupPending == false)
		await store.failTransaction(commit: .beforeEffect)
		await #expect(throws: StoreError.self) { try await perform(op, store, clip, deleted) }
		#expect(try await store.recent() == rows)
		#expect(try dataFiles(dir) == before)
		#expect(await store.cleanupPending == false)
		try await perform(op, store, clip, deleted)
		#expect(await store.cleanupPending == false)
	}

	@Test func failedPreviewPublicationCannotHideUnownedThumbnailDebt() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/failed"))
		files.failRemoveContaining = ".png"
		#expect(try await store.setPreview(key: clip.key, generation: clip.generation, state: .failed, image: Data([1])))
		#expect(await store.thumbnail(for: clip.key) == nil)
		#expect(await store.cleanupPending)
		try await store.removeOrphans()
		#expect(fileCount(dir, "thumbs") == 0)
		#expect(await store.cleanupPending == false)
	}

	@Test func directoryListingUnavailableDoesNotPreventSingleItemPaste() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("paste without listing")
		let (clip, _) = try await store.insert(draft)
		files.listCalls = 0; files.readCalls = 0
		files.failListContaining = "blobs"
		#expect(try await store.items(for: clip.key) == draft.items)
		#expect(files.listCalls == 0)
		#expect(files.readCalls == 1)
		let blob = dir.appendingPathComponent("blobs/\(clip.key).plist")
		try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blob.path)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blob.path) }
		await #expect(throws: (any Error).self) { try await store.items(for: clip.key) }
	}

	@Test func legacyFallbackRequiresAnActuallyMissingHomeBlob() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("legacy readable")
		let (clip, _) = try await store.insert(draft)
		let home = dir.appendingPathComponent("blobs/\(clip.key).plist")
		let legacy = dir.appendingPathComponent("trash/\(clip.key).plist")
		try FileManager.default.copyItem(at: home, to: legacy)
		files.hideContaining = "blobs/"
		files.listCalls = 0; files.readCalls = 0
		await #expect(throws: CocoaError(.fileReadNoPermission)) { try await store.items(for: clip.key) }
		#expect(files.listCalls == 0 && files.readCalls == 1)
		files.hideContaining = nil
		try FileManager.default.removeItem(at: home)
		files.failListContaining = "trash"
		#expect(try await store.items(for: clip.key) == draft.items)
		#expect(try Data(contentsOf: legacy) == ClipStore.encode(draft.items))
	}

	@Test func targetedDeleteCleanupDoesNotScanHistoryOrDirectories() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/target"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([3]))
		for i in 0..<100 { try await store.insert(text("unrelated \(i)")) }
		files.listCalls = 0
		await store.resetReadCounts()
		let deleted = try #require(try await store.delete(clip.key))
		#expect(files.listCalls == 0)
		#expect(await store.readRowCount < 20)
		#expect(fileCount(dir, "blobs") == 100 && fileCount(dir, "thumbs") == 0)
		try await store.restore(deleted)
		#expect(files.listCalls == 0)
	}

	@Test func cleanupStatusReadsAreCachedUntilAFullScan() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		#expect(await store.cleanupPending == false)
		files.listCalls = 0
		await store.resetReadCounts()
		for _ in 0..<5 { #expect(await store.cleanupPending == false) }
		#expect(files.listCalls == 0)
		#expect(await store.readStatementCount == 0)
		let (clip, _) = try await store.insert(text("debt"))
		files.failRemoveContaining = "blobs/"
		_ = try await store.delete(clip.key)
		#expect(await store.cleanupPending)
		try FileManager.default.removeItem(at: dir.appendingPathComponent("blobs/\(clip.key).plist"))
		#expect(await store.cleanupPending)
		try await store.removeOrphans()
		#expect(await store.cleanupPending == false)
	}

	@Test func snapshotUsesOneRowQueryAndKeepsThumbnailOwnership() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (pending, _) = try await store.insert(text("https://example.com/pending", at: 1))
		let (final, _) = try await store.insert(text("https://example.com/final", at: 2))
		try await store.setPreview(key: final.key, generation: final.generation, state: .ok, image: Data([3]))
		try Data([9]).write(to: dir.appendingPathComponent("thumbs/\(pending.key).png"))
		for i in 0..<100 { try await store.insert(text("unrelated \(i)", at: TimeInterval(i + 3))) }
		files.listCalls = 0
		await store.resetReadCounts()
		let snapshot = try await store.snapshot()
		#expect(snapshot.count == 102)
		#expect(snapshot.suffix(2).map { $0.clip.key } == [final.key, pending.key])
		#expect(snapshot.first { $0.clip.key == pending.key }?.thumbnail == nil)
		let thumbnail = try #require(snapshot.first { $0.clip.key == final.key }?.thumbnail)
		#expect(try Data(contentsOf: thumbnail) == Data([3]))
		#expect(await store.readStatementCount == 1)
		#expect(await store.readRowCount == 102)
		#expect(files.listCalls == 0)
		_ = try await store.delete(final.key)
		#expect(try await store.snapshot().contains { $0.clip.key == final.key } == false)
		await store.failNextStep()
		await #expect(throws: StoreError.self) { try await store.snapshot() }
	}

	@Test func eraseListingFailureCountsOnlyFilesNotAlreadyRemoved() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		try await store.insert(text("one"))
		try await store.insert(text("two"))
		files.failRemoveContaining = ".plist"
		files.failListAfter = 3
		await #expect(throws: StoreError.filesLeft(1)) { try await store.eraseAll() }
		#expect(try await store.recent().isEmpty)
		#expect(fileCount(dir, "blobs") == 1)
		#expect(await store.cleanupPending)
	}

	@Test func sweepCleanupReadFailureDoesNotMisreportCommittedRowRemoval() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("missing"))
		try FileManager.default.removeItem(at: dir.appendingPathComponent("blobs/\(clip.key).plist"))
		files.failListAfter = 3
		try await store.sweep()
		#expect(try await store.fetch(clip.key) == nil)
		#expect(try await store.ftsKeys().isEmpty)
		#expect(await store.cleanupPending)
	}

	@Test(arguments: writes)
	func commitBeforeEffectRollsBackEveryWrite(op: String) async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, deleted) = try await writeFixture(op, store)
		let rows = try await store.recent(), fts = try await store.ftsKeys(), before = try dataFiles(dir)
		await store.failTransaction(commit: .beforeEffect)
		await #expect(throws: StoreError.self) { try await perform(op, store, clip, deleted) }
		#expect(await store.recoveryRequired == false)
		#expect(try await store.recent() == rows)
		#expect(try await store.ftsKeys() == fts)
		#expect(try dataFiles(dir) == before)
		if let deleted { try await store.restore(deleted) }
	}

	@Test func unreadableLegacySourceRejectsRecopyBeforeMutation() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (legacy, _) = try await store.insert(text("legacy"))
		try FileManager.default.moveItem(at: dir.appendingPathComponent("blobs/\(legacy.key).plist"), to: dir.appendingPathComponent("trash/\(legacy.key).plist"))
		let source = dir.appendingPathComponent("trash/\(legacy.key).plist")
		try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }
		await #expect(throws: (any Error).self) { try await store.insert(text("legacy")) }
		#expect(try await store.fetch(legacy.key) == legacy)
	}

	@Test func failedStagingCleanupDebtKeepsOwnedSnapshotAndExpiresOnRestore() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("https://example.com/staging")
		let (clip, _) = try await store.insert(draft)
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([3]))
		let deleted = try #require(try await store.delete(clip.key))
		files.failCopyContaining = ".png"
		files.failRemoveContaining = "blobs/"
		await #expect(throws: (any Error).self) { try await store.restore(deleted) }
		#expect(await store.cleanupPending)
		#expect(fileCount(dir, "trash") == 2)
		try await store.removeOrphans()
		#expect(fileCount(dir, "trash") == 2)
		files.failRemoveContaining = "trash/"
		try await store.restore(deleted)
		await #expect(throws: StoreError.undoExpired) { try await store.restore(deleted) }
		#expect(await store.cleanupPending)
		try await store.removeOrphans()
		#expect(await store.cleanupPending == false)
		#expect(try await store.items(for: clip.key) == draft.items)
		let again = try #require(try await store.delete(clip.key))
		try FileManager.default.removeItem(at: dir.appendingPathComponent("trash/\(clip.key).\(again.token.uuidString).png"))
		// External changes become known at the next explicit scan, not a cached status read.
		try await store.removeOrphans()
		#expect(await store.cleanupPending)
	}

	@Test(arguments: ["recopy", "preview"])
	func missingLiveBlobRejectsWritesWithoutMutation(op: String) async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("https://example.com/missing")
		let (clip, _) = try await store.insert(draft)
		try FileManager.default.removeItem(at: dir.appendingPathComponent("blobs/\(clip.key).plist"))
		await #expect(throws: StoreError.missingBlob) {
			if op == "recopy" { try await store.insert(draft) }
			else { try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1])) }
		}
		#expect(try await store.fetch(clip.key) == clip)
		#expect(fileCount(dir, "thumbs") == 0)
	}

	@Test func pendingPreviewCannotPublishAnotherPendingImage() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/pending"))
		#expect(try await store.setPreview(key: clip.key, generation: clip.generation, state: .pending, image: Data([1])) == false)
		#expect(try await store.fetch(clip.key) == clip)
		#expect(fileCount(dir, "thumbs") == 0)
	}

	@Test func unreadableSavedThumbnailCannotBeSilentlyOmittedFromSnapshot() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/thumbnail"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		let before = try dataFiles(dir)
		files.hideContaining = "thumbs/"
		await #expect(throws: (any Error).self) { try await store.delete(clip.key) }
		files.hideContaining = nil
		#expect(try dataFiles(dir) == before)
		#expect(try await store.fetch(clip.key) != nil)
	}

	@Test func cleanupFailureReturnsCommittedDeleteAndWarning() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("cleanup"))
		files.failRemoveContaining = "blobs/"
		let deleted = try #require(try await store.delete(clip.key))
		#expect(try await store.fetch(clip.key) == nil)
		#expect(await store.cleanupPending)
		try await store.restore(deleted)
		#expect(try await store.items(for: clip.key) == text("cleanup").items)
	}

	@Test func cleanupWarningSurvivesUntilVerifiedScan() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("cleanup"))
		files.failRemoveContaining = "blobs/"
		_ = try await store.delete(clip.key)
		#expect(await store.cleanupPending)
		files.failListContaining = "thumbs"
		await #expect(throws: (any Error).self) { try await store.removeOrphans() }
		#expect(fileCount(dir, "blobs") == 1)
		#expect(await store.cleanupPending)
		files.failListContaining = nil
		try await store.removeOrphans()
		#expect(await store.cleanupPending == false)
		#expect(fileCount(dir, "trash") == 1)
	}

	@Test func eraseStillReportsEveryRemainingFile() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("erase"))
		_ = try await store.delete(clip.key)
		try Data([1]).write(to: dir.appendingPathComponent("thumbs/.atomic-leftover"))
		files.failRemoveContaining = "trash/"
		await store.failTransaction(commit: .afterEffect)
		await #expect(throws: StoreError.filesLeft(1)) { try await store.eraseAll() }
		#expect(try await store.recent().isEmpty)
		#expect(await store.recoveryRequired == false)
		#expect(await store.cleanupPending)
		#expect(fileCount(dir, "trash") == 1)
		try await store.removeOrphans()
		#expect(await store.cleanupPending == false)
	}

	@Test func pruneAndAtomicTempsSetCleanupDebt() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("old", at: 100))
		files.failRemoveContaining = clip.key
		#expect(try await store.prune(before: Date(timeIntervalSince1970: 200)) == 1)
		#expect(await store.cleanupPending)
		try await store.removeOrphans()
		#expect(await store.cleanupPending == false)
		files.failAtomicWrite = true
		await #expect(throws: (any Error).self) { try await store.insert(text("new")) }
		#expect(await store.cleanupPending)
		let reopened = try ClipStore(directory: dir)
		#expect(await reopened.cleanupPending)
		try await reopened.sweep()
		#expect(await reopened.cleanupPending == false)
	}

	@Test func unreadableListingStopsAllCleanupBeforeAnyUnlink() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("undo"))
		let deleted = try #require(try await store.delete(clip.key))
		files.failListContaining = "thumbs"
		// An explicit scan discovers unreadable-directory debt; close retries that debt without unlinking.
		await #expect(throws: (any Error).self) { try await store.removeOrphans() }
		await store.emptyTrash()
		#expect(fileCount(dir, "trash") == 1)
		await #expect(throws: StoreError.undoExpired) { try await store.restore(deleted) }
		#expect(await store.cleanupPending)
		files.failListContaining = nil
		try await store.removeOrphans()
		#expect(fileCount(dir, "trash") == 0)
	}

	@Test func unownedThumbnailBlocksPublishIfRemovalFails() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("https://example.com/new")
		let thumbnail = dir.appendingPathComponent("thumbs/\(draft.contentKey).png")
		try Data([8]).write(to: thumbnail)
		files.failRemoveContaining = ".png"
		await #expect(throws: (any Error).self) { try await store.insert(draft) }
		#expect(try await store.fetch(draft.contentKey) == nil)
		#expect(try Data(contentsOf: thumbnail) == Data([8]))
		try await store.insert(draft)
		#expect(await store.thumbnail(for: draft.contentKey) == nil)
	}

	@Test func oldTrashThumbnailNeverBecomesNewIcon() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("https://example.com/new")
		try Data([8]).write(to: dir.appendingPathComponent("trash/\(draft.contentKey).png"))
		try Data([9]).write(to: dir.appendingPathComponent("thumbs/\(draft.contentKey).png"))
		let (clip, _) = try await store.insert(draft)
		try await store.removeOrphans()
		#expect(await store.thumbnail(for: clip.key) == nil)
		#expect(fileCount(dir, "trash") == 0)
	}

	@Test func finalPreviewRejectsReplacementAndDemotion() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/final"))
		#expect(try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Saved", image: Data([7])))
		let before = try await store.fetch(clip.key)
		#expect(try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Changed", image: Data([8])) == false)
		#expect(try await store.setPreview(key: clip.key, generation: clip.generation, state: .pending) == false)
		#expect(try await store.fetch(clip.key) == before)
		#expect(try Data(contentsOf: dir.appendingPathComponent("thumbs/\(clip.key).png")) == Data([7]))
		#expect(try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Indexed"))
		#expect(try await store.search("Indexed") == [clip.key])
	}

	@Test func rolledBackPreviewLeftoverDoesNotBlockRetry() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/retry"))
		await store.failNextWrite()
		files.failRemoveContaining = ".png"
		await #expect(throws: StoreError.self) { try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([8])) }
		#expect(fileCount(dir, "thumbs") == 1)
		#expect(await store.thumbnail(for: clip.key) == nil)
		#expect(try await store.setPreview(key: clip.key, generation: clip.generation, state: .okNoImage, title: "No icon"))
		#expect(await store.thumbnail(for: clip.key) == nil)
		#expect(fileCount(dir, "thumbs") == 0)
	}

	@Test func restoreWithoutRequiredThumbnailKeepsUndo() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("https://example.com/saved")
		let (clip, _) = try await store.insert(draft)
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Saved", image: Data([7]))
		let deleted = try #require(try await store.delete(clip.key))
		let thumbnail = dir.appendingPathComponent("trash/\(clip.key).\(deleted.token.uuidString).png")
		try FileManager.default.removeItem(at: thumbnail)
		await #expect(throws: StoreError.missingThumbnail) { try await store.restore(deleted) }
		#expect(try await store.fetch(clip.key) == nil)
		#expect(try await store.pending().isEmpty)
		#expect(fileCount(dir, "blobs") == 0)
		try Data([7]).write(to: thumbnail)
		let restored = try await store.restore(deleted)
		#expect(restored.previewState == .ok && restored.title == "Saved")
		#expect(restored.generation != clip.generation)
		#expect(try await store.items(for: clip.key) == draft.items)
	}

	@Test func failedRecopyKeepsAuthoritativeSnapshot() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("https://example.com/saved")
		let (clip, _) = try await store.insert(draft)
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Saved", image: Data([7]))
		let deleted = try #require(try await store.delete(clip.key))
		let before = try dataFiles(dir)
		try await store.rejectNewRows(true)
		await #expect(throws: StoreError.self) { try await store.insert(draft) }
		try await store.rejectNewRows(false)
		#expect(try dataFiles(dir) == before)
		try await store.removeOrphans()
		let back = try await store.restore(deleted)
		#expect(back.title == "Saved" && back.previewState == .ok)
	}

	@Test func snapshotTokensRejectOldHandleAfterRedelete() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("token"))
		let old = try #require(try await store.delete(clip.key))
		try await store.restore(old)
		let new = try #require(try await store.delete(clip.key))
		#expect(old.token != new.token)
		#expect(new.issuedSequence > old.issuedSequence)
		await #expect(throws: StoreError.undoExpired) { try await store.restore(old) }
		try await store.restore(new)
	}

	@Test func expiredUndoCannotRestoreLeftoverSnapshot() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("token"))
		let deleted = try #require(try await store.delete(clip.key))
		files.failRemoveContaining = ".plist"
		await store.invalidateUndo(deleted)
		#expect(fileCount(dir, "trash") == 1)
		await #expect(throws: StoreError.undoExpired) { try await store.restore(deleted) }
		try await store.removeOrphans()
		#expect(fileCount(dir, "trash") == 0)
	}

	@Test func snapshotFilenameDistinguishesLegacyFromToken() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("token"))
		let deleted = try #require(try await store.delete(clip.key))
		let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("trash").path)
		#expect(names == ["\(clip.key).\(deleted.token.uuidString).plist"])
	}

	@Test func closeCutoffKeepsReopenedDeletion() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (first, _) = try await store.insert(text("one"))
		let (second, _) = try await store.insert(text("two"))
		let old = try #require(try await store.delete(first.key))
		let reopened = try #require(try await store.delete(second.key))
		await store.emptyTrash(through: old.issuedSequence)
		await #expect(throws: StoreError.undoExpired) { try await store.restore(old) }
		try await store.restore(reopened)
		await store.invalidateUndo(old)
		#expect(try await store.items(for: second.key) == text("two").items)
	}

	@Test func missingBlobFailsWithoutMutation() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("missing"))
		try FileManager.default.removeItem(at: dir.appendingPathComponent("blobs/\(clip.key).plist"))
		await #expect(throws: StoreError.missingBlob) { try await store.delete(clip.key) }
		#expect(try await store.fetch(clip.key) == clip)
		#expect(try await store.ftsKeys() == [clip.key])
	}

	@Test func rowGatePreventsGhostPayloadReads() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("ghost"))
		files.failRemoveContaining = "blobs/"
		_ = try await store.delete(clip.key)
		await #expect(throws: StoreError.missingBlob) { try await store.items(for: clip.key) }
	}

	private static let writes = ["insert", "recopy", "preview", "delete", "restore", "prune", "erase"]

	private func writeFixture(_ op: String, _ store: ClipStore) async throws -> (StoredClip, DeletedClip?) {
		let (clip, _) = try await store.insert(text("https://example.com/original", at: 100))
		if op == "restore" {
			try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Saved", image: Data([7]))
			return (clip, try await store.delete(clip.key))
		}
		return (clip, nil)
	}

	private func perform(_ op: String, _ store: ClipStore, _ clip: StoredClip, _ deleted: DeletedClip?) async throws {
		switch op {
		case "insert": try await store.insert(text("https://example.com/new"))
		case "recopy": try await store.insert(text("https://example.com/original", at: 200))
		case "preview": try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Saved", image: Data([7]))
		case "delete": _ = try await store.delete(clip.key)
		case "restore": try await store.restore(try #require(deleted))
		case "prune": try await store.prune(before: Date(timeIntervalSince1970: 150))
		default: try await store.eraseAll()
		}
	}

	@Test(arguments: writes)
	func commitErrorAfterCommitIsClassifiedForEveryWrite(op: String) async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, deleted) = try await writeFixture(op, store)
		await store.failTransaction(commit: .afterEffect)
		try await perform(op, store, clip, deleted)
		#expect(await store.recoveryRequired == false)
		switch op {
		case "insert": #expect(try await store.items(for: text("https://example.com/new").contentKey) == text("https://example.com/new").items)
		case "recopy":
			#expect(try await store.fetch(clip.key)?.copyCount == 2)
			#expect(try await store.fetch(clip.key)?.lastCopied == Date(timeIntervalSince1970: 200))
		case "preview", "restore":
			#expect(try await store.fetch(clip.key)?.title == "Saved")
			#expect(try await store.search("Saved") == [clip.key])
			let thumb = try #require(await store.thumbnail(for: clip.key))
			#expect(try Data(contentsOf: thumb) == Data([7]))
			#expect(try await store.items(for: clip.key) == text("https://example.com/original").items)
		default:
			#expect(try await store.fetch(clip.key) == nil)
			#expect(try await store.ftsKeys().isEmpty)
		}
	}

	@Test(arguments: writes)
	func commitAndRollbackFailureFreezesStoreWithoutCleanup(op: String) async throws {
		try await expectUnknown(op, rollback: true)
	}

	@Test(arguments: writes)
	func failedReadbackPreservesAllCopies(op: String) async throws {
		try await expectUnknown(op, rollback: false)
	}

	private func expectUnknown(_ op: String, rollback: Bool) async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, deleted) = try await writeFixture(op, store)
		let before = try dataFiles(dir)
		await store.failTransaction(commit: rollback ? .beforeEffect : .afterEffect, rollback: rollback, readback: !rollback)
		await #expect(throws: StoreError.outcomeUnknown) { try await perform(op, store, clip, deleted) }
		#expect(await store.recoveryRequired)
		let frozen = try dataFiles(dir)
		for (url, bytes) in before { #expect(frozen[url] == bytes) }
		await #expect(throws: StoreError.outcomeUnknown) { try await store.recent() }
		await #expect(throws: StoreError.outcomeUnknown) { try await store.snapshot() }
		await #expect(throws: StoreError.outcomeUnknown) { try await store.fetch(clip.key) }
		await #expect(throws: StoreError.outcomeUnknown) { try await store.search("original") }
		await #expect(throws: StoreError.outcomeUnknown) { try await store.pending() }
		await #expect(throws: StoreError.outcomeUnknown) { try await store.items(for: clip.key) }
		#expect(await store.thumbnail(for: clip.key) == nil)
		for write in Self.writes {
			await #expect(throws: StoreError.outcomeUnknown) { try await perform(write, store, clip, deleted ?? DeletedClip(clip: clip, hadThumbnail: false, token: UUID(), issuedSequence: 0)) }
		}
		await store.emptyTrash()
		await #expect(throws: StoreError.outcomeUnknown) { try await store.removeOrphans() }
		await #expect(throws: StoreError.outcomeUnknown) { try await store.sweep() }
		#expect(try dataFiles(dir) == frozen)
	}

	private func dataFiles(_ dir: URL) throws -> [URL: Data] {
		var result: [URL: Data] = [:]
		for name in ["blobs", "thumbs", "trash"] {
			for url in try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent(name), includingPropertiesForKeys: nil) {
				result[url] = try Data(contentsOf: url)
			}
		}
		return result
	}

	@Test func failedDeleteStagingKeepsExactLiveFiles() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let draft = text("https://example.com/saved")
		let (clip, _) = try await store.insert(draft)
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Saved title", image: Data([1, 2, 3]))
		let before = try #require(try await store.fetch(clip.key))
		let blob = dir.appendingPathComponent("blobs/\(clip.key).plist")
		let thumbnail = dir.appendingPathComponent("thumbs/\(clip.key).png")
		let bytes = try Data(contentsOf: blob)
		faulty.failCopyContaining = ".png"
		await #expect(throws: (any Error).self) { try await store.delete(clip.key) }
		#expect(try await store.fetch(clip.key) == before)
		#expect(try await store.search("Saved title") == [clip.key])
		#expect(try await store.items(for: clip.key) == draft.items)
		#expect(try Data(contentsOf: blob) == bytes)
		#expect(try Data(contentsOf: thumbnail) == Data([1, 2, 3]))
	}

	@Test func failedRestoreStagingKeepsExactUndoFiles() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/saved"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Saved title", image: Data([1, 2, 3]))
		let deleted = try #require(try await store.delete(clip.key))
		let snapshots = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("trash"), includingPropertiesForKeys: nil)
		let before = try Dictionary(uniqueKeysWithValues: snapshots.map { ($0, try Data(contentsOf: $0)) })
		faulty.failCopyContaining = ".png"
		try await store.rejectNewRows(true)
		await #expect(throws: (any Error).self) { try await store.restore(deleted) }
		#expect(try await store.fetch(clip.key) == nil)
		#expect(try await store.ftsKeys().isEmpty)
		for (url, bytes) in before { #expect(try Data(contentsOf: url) == bytes) }
		try await store.rejectNewRows(false)
	}

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
		let (clip, _) = try await store.insert(text("https://example.com/delete-me"))
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
		await #expect(throws: StoreError.undoExpired) { try await store.restore(again) }
		#expect(try await store.fetch(clip.key) == nil)
	}

	@Test func restoreAfterRecopyIsRefused() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("dup"))
		let deleted = try #require(try await store.delete(clip.key))
		try await store.insert(text("dup"))
		await #expect(throws: StoreError.undoExpired) { try await store.restore(deleted) }
	}

	@Test func stalePreviewWritesNothingAfterDeleteOrRecopy() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/x"))
		_ = try await store.delete(clip.key)
		#expect(try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([9])) == false)
		let (fresh, _) = try await store.insert(text("https://example.com/x"))
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
		let (clip, _) = try await store.insert(text("https://example.com/orphan"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		faulty.failCopyContaining = "blobs"
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

	/// A failed thumbnail copy never changes either authoritative live file.
	@Test func aFailedThumbnailCopyToTrashKeepsTheWholeClip() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/orphan"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		faulty.failCopyContaining = "thumbs"
		await #expect(throws: (any Error).self) { try await store.delete(clip.key) }
		try await expectWhole(store, dir, clip)
		try await store.sweep()
		try await expectWhole(store, dir, clip)
	}

	/// SQL rejection removes only staged duplicates; the live files never left home.
	@Test func aFailedRowDeleteKeepsTheExactFiles() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/orphan"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		await store.failNextWrite()
		await #expect(throws: StoreError.self) { try await store.delete(clip.key) }
		try await expectWhole(store, dir, clip)
		try await store.sweep()
		try await expectWhole(store, dir, clip)
	}

	/// Legacy stores may have a live blob in trash after an old rename rollback failed.
	private func strandBlobInTrash(_ store: ClipStore, _ dir: URL, _ faulty: FaultyFiles) async throws -> StoredClip {
		let (clip, _) = try await store.insert(text("https://example.com/keep-me"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		try FileManager.default.moveItem(at: dir.appendingPathComponent("blobs/\(clip.key).plist"),
			to: dir.appendingPathComponent("trash/\(clip.key).plist"))
		#expect(try await store.items(for: clip.key) == text("https://example.com/keep-me").items)
		#expect(fileCount(dir, "blobs") == 0 && fileCount(dir, "trash") == 1)
		return clip
	}

	/// Cleanup copies a legacy live blob home before removing its fallback.
	@Test(arguments: ["emptyTrash", "sweep", "removeOrphans"])
	func legacyBlobIsImmediatelyReadableAndRecoveredBeforeCleanup(pass: String) async throws {
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

	@Test func legacyTrashThumbnailIsNeverAdopted() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/keep-me"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		try FileManager.default.moveItem(at: dir.appendingPathComponent("thumbs/\(clip.key).png"),
			to: dir.appendingPathComponent("trash/\(clip.key).png"))
		let reopened = try ClipStore(directory: dir)
		#expect(await reopened.cleanupPending)
		await reopened.emptyTrash()
		#expect(try await store.fetch(clip.key)?.previewState == .ok)
		#expect(try await store.items(for: clip.key) == text("https://example.com/keep-me").items)
		#expect(await store.thumbnail(for: clip.key) == nil)
		#expect(fileCount(dir, "trash") == 0)
	}

	/// Failed legacy recovery preserves its source and row until a later copy succeeds.
	@Test func samePathLegacyBlobIsNeverUnlinkedOnFailure() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let clip = try await strandBlobInTrash(store, dir, faulty)
		faulty.failCopyContaining = "trash/\(clip.key).plist"
		await store.emptyTrash()
		#expect(try await store.fetch(clip.key) != nil)
		#expect(fileCount(dir, "trash") == 1)
		faulty.failCopyContaining = "trash/\(clip.key).plist"
		try await store.sweep()
		#expect(try await store.fetch(clip.key) != nil)
		#expect(fileCount(dir, "trash") == 1)
		try await store.sweep()
		try await expectWhole(store, dir, clip)
	}

	/// A blob the store cannot reach is not an absent one: the delete fails and nothing changes (B1:64).
	@Test func aBlobItCannotReachFailsTheDeleteAndKeepsTheClip() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/unreachable"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		faulty.hideContaining = "blobs/"
		await #expect(throws: (any Error).self) { try await store.delete(clip.key) }
		faulty.hideContaining = nil
		try await expectWhole(store, dir, clip)
		_ = try #require(try await store.delete(clip.key))
		#expect(fileCount(dir, "blobs") + fileCount(dir, "thumbs") == 0)
		#expect(fileCount(dir, "trash") == 2)
	}

	/// The same with a real folder that lists but cannot be searched.
	@Test func aBlobsFolderWithoutSearchPermissionFailsTheDelete() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/unreachable"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		let blobs = dir.appendingPathComponent("blobs").path
		try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: blobs)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobs) }
		await #expect(throws: (any Error).self) { try await store.delete(clip.key) }
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobs)
		try await expectWhole(store, dir, clip)
		_ = try #require(try await store.delete(clip.key))
		#expect(fileCount(dir, "blobs") == 0)
	}

	/// Deleting again before any cleanup pass keeps a blob stranded in trash as the undo copy.
	@Test func aSecondDeleteKeepsAStrandedBlobAsItsUndo() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let clip = try await strandBlobInTrash(store, dir, faulty)
		let deleted = try #require(try await store.delete(clip.key))
		#expect(try await store.fetch(clip.key) == nil)
		#expect(fileCount(dir, "trash") == 2)
		try await store.restore(deleted)
		try await expectWhole(store, dir, clip)
	}

	/// Copying a missing source preserves the destination; successful and same-path copies preserve the source.
	@Test func liveCopyOfAMissingSourceKeepsTheDestination() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-mv-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let dest = dir.appendingPathComponent("dest.plist")
		try Data("undo copy".utf8).write(to: dest)
		#expect(throws: (any Error).self) { try LiveFileOps().copy(dir.appendingPathComponent("missing.plist"), to: dest) }
		#expect(try Data(contentsOf: dest) == Data("undo copy".utf8))
		let source = dir.appendingPathComponent("source.plist")
		try Data("new".utf8).write(to: source)
		try LiveFileOps().copy(source, to: dest)
		#expect(try Data(contentsOf: dest) == Data("new".utf8))
		#expect(FileManager.default.fileExists(atPath: source.path))
		try LiveFileOps().copy(source, to: source)
		#expect(try Data(contentsOf: source) == Data("new".utf8))
	}

	/// SQL rejection after staging keeps both snapshot files exact and retryable.
	private func failRestoreCompletely(_ store: ClipStore, _ dir: URL, _ faulty: FaultyFiles) async throws -> (StoredClip, DeletedClip) {
		let (clip, _) = try await store.insert(text("https://example.com/keep-me"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		let deleted = try #require(try await store.delete(clip.key))
		let before = try dataFiles(dir)
		try await store.rejectNewRows(true)
		await #expect(throws: StoreError.self) { try await store.restore(deleted) }
		try await store.rejectNewRows(false)
		#expect(try await store.fetch(clip.key) == nil)
		#expect(try dataFiles(dir) == before)
		#expect(fileCount(dir, "blobs") == 0 && fileCount(dir, "trash") == 2)
		return (clip, deleted)
	}

	/// Hourly cleanup preserves both authoritative snapshot files and allows a complete retry.
	@Test func failedRestoreSQLKeepsCompleteSnapshotForHourlyPassAndRetry() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, deleted) = try await failRestoreCompletely(store, dir, faulty)
		try await store.removeOrphans()
		#expect(fileCount(dir, "blobs") == 0 && fileCount(dir, "trash") == 2)
		try await store.restore(deleted)
		try await expectWhole(store, dir, clip)
		#expect(try await store.fetch(clip.key)?.previewState == .ok)
	}

	/// Close, sweep and erase expire failed-restore snapshots; leftover files never grant permission to restore.
	@Test(arguments: ["emptyTrash", "sweep", "eraseAll"])
	func endingTheUndoRemovesAFailedRestoresPayload(pass: String) async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, deleted) = try await failRestoreCompletely(store, dir, faulty)
		switch pass {
		case "emptyTrash": await store.emptyTrash()
		case "sweep": try await store.sweep()
		default: try await store.eraseAll()
		}
		#expect(fileCount(dir, "blobs") + fileCount(dir, "thumbs") + fileCount(dir, "trash") == 0)
		await #expect(throws: StoreError.undoExpired) { try await store.restore(deleted) }
		#expect(try await store.fetch(clip.key) == nil)
		try Data([1]).write(to: dir.appendingPathComponent("blobs/\(clip.key).plist"))
		try await store.removeOrphans()
		#expect(fileCount(dir, "blobs") == 0)
	}

	/// A rejected recopy cannot consume the complete snapshot from a previously failed restore.
	@Test func failedRecopyAfterFailedRestoreKeepsCompleteSnapshot() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, deleted) = try await failRestoreCompletely(store, dir, faulty)
		try await store.rejectNewRows(true)
		await #expect(throws: StoreError.self) { try await store.insert(text("https://example.com/keep-me")) }
		try await store.rejectNewRows(false)
		#expect(try await store.fetch(clip.key) == nil)
		#expect(fileCount(dir, "blobs") == 0 && fileCount(dir, "trash") == 2)
		try await store.removeOrphans()
		#expect(fileCount(dir, "blobs") == 0 && fileCount(dir, "trash") == 2)
		try await store.restore(deleted)
		try await expectWhole(store, dir, clip)
	}

	/// A failed insert of new content still leaves no blob behind.
	@Test func aFailedInsertOfNewContentLeavesNoBlob() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		try await store.rejectNewRows(true)
		await #expect(throws: StoreError.self) { try await store.insert(text("new")) }
		try await store.rejectNewRows(false)
		#expect(fileCount(dir, "blobs") == 0)
		#expect(try await store.ftsKeys().isEmpty)
		try await store.insert(text("new"))
		#expect(fileCount(dir, "blobs") == 1)
	}

	/// A successful restore or recopy expires the token; a later failed prune unlink is ordinary cleanup debt.
	@Test(arguments: ["restore", "recopy"])
	func snapshotExpiresWhenTheClipIsBack(how: String) async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, deleted) = try await failRestoreCompletely(store, dir, faulty)
		if how == "restore" { try await store.restore(deleted) } else { try await store.insert(text("https://example.com/keep-me")) }
		faulty.failRemoveContaining = "blobs/\(clip.key).plist"
		#expect(try await store.prune(before: Date(timeIntervalSince1970: 1_900_000_000)) == 1)
		#expect(fileCount(dir, "blobs") == 1)
		try await store.removeOrphans()
		#expect(fileCount(dir, "blobs") + fileCount(dir, "thumbs") == 0)
	}

	@Test func expiredUndoWithLeftoverBlobNeverRequestsANewPreview() async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/post"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Saved", image: Data([1]))
		let deleted = try #require(try await store.delete(clip.key))
		faulty.failRemoveContaining = ".plist"
		await store.emptyTrash()
		#expect(fileCount(dir, "trash") == 1)
		await #expect(throws: StoreError.undoExpired) { try await store.restore(deleted) }
		#expect(try await store.pending().isEmpty)
		#expect(try await store.fetch(clip.key) == nil)
	}

	@Test func recopyingADeletedItemEmptiesItsTrash() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("https://example.com/again"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		_ = try await store.delete(clip.key)
		#expect(fileCount(dir, "trash") == 2)
		try await store.insert(text("https://example.com/again"))
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
		let (clip, _) = try await store.insert(text("https://example.com/roll"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		let deleted = try #require(try await store.delete(clip.key))
		faulty.failCopyContaining = ".png"
		await #expect(throws: (any Error).self) { try await store.restore(deleted) }
		#expect(try await store.fetch(clip.key) == nil)
		#expect(try await store.search("roll").isEmpty)
		#expect(fileCount(dir, "blobs") == 0)
		#expect(fileCount(dir, "trash") == 2)
		try await store.restore(deleted)
		#expect(try await store.fetch(clip.key) != nil)
	}

	/// Checked in the FTS table itself: search joins on `clips`, so it would hide an entry the sweep left behind.
	@Test func sweepDropsRowsWithMissingBlobsAndTheirFts() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await store.insert(text("lost blob"))
		let (kept, _) = try await store.insert(text("kept blob"))
		try FileManager.default.removeItem(at: dir.appendingPathComponent("blobs/\(clip.key).plist"))
		try await store.sweep()
		#expect(try await store.fetch(clip.key) == nil)
		#expect(try await store.search("lost").isEmpty)
		#expect(try await store.ftsKeys() == [kept.key])
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
		let (clip, _) = try await store.insert(text("https://example.com/a1"))
		try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		let (other, _) = try await store.insert(text("https://example.com/b2"))
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
		let (old, _) = try await store.insert(text("https://example.com/old", at: 100))
		try await store.setPreview(key: old.key, generation: old.generation, state: .ok, image: Data([1]))
		let (new, _) = try await store.insert(text("https://example.com/new", at: 1_000))
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
