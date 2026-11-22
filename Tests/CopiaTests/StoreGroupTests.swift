import Testing
import Foundation
import CopiaCore
@testable import CopiaStore

@Suite struct StoreGroupTests {
	/// Each member has distinct live bytes, a finalized thumbnail and a known generation.
	private func pair(_ store: ClipStore, startingAt first: Int = 1) async throws -> [StoredClip] {
		var clips: [StoredClip] = []
		for i in first...(first + 1) {
			let (clip, _) = try await store.insert(text("https://example.com/group/\(i)"))
			try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([UInt8(i)]))
			clips.append(try #require(try await store.fetch(clip.key)))
		}
		return clips
	}

	@Test func orderedGroupRestoresFreshGenerationsAndLeavesNonmemberRowFTSAndFilesUntouched() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		var clips = Array(try await pair(store).reversed())
		try await store.setPinned(clips[0].key, to: true)
		clips[0].isPinned = true
		let keys = clips.map(\.key)
		let draft = text("https://example.com/untouched", at: 123)
		let (other, _) = try await store.insert(draft)
		let image = Data([0, 9, 0, 8])
		try await store.setPreview(key: other.key, generation: other.generation, state: .ok, title: "Untouched", image: image)
		let kept = try #require(try await store.fetch(other.key)), blob = await store.blobURL(other.key)
		let thumb = try #require(await store.thumbnail(for: other.key)), bytes = try Data(contentsOf: blob)
		let fts = "SELECT rowid,id,title,preview_text FROM clips_fts WHERE id='\(other.key)' ORDER BY rowid"
		let entry = try sqlTextRows(dir, fts)
		try #require(entry.count == 1)
		func expectNonmemberUnchanged() async throws {
			#expect(try await store.fetch(other.key) == kept) // Includes its original generation.
			#expect(try sqlTextRows(dir, fts) == entry)
			#expect(try await store.search("Untouched") == [other.key])
			#expect(try await store.items(for: other.key) == draft.items)
			#expect(try Data(contentsOf: blob) == bytes)
			#expect(try Data(contentsOf: thumb) == image)
		}
		for bad in [[], [keys[0], keys[0]], [keys[0], "missing"]] {
			await #expect(throws: StoreError.self) { try await store.deleteGroup(bad) }
		}
		#expect(fileCount(dir, "trash") == 0)
		await store.failTransaction(commit: .afterEffect)
		let group = try await store.deleteGroup(keys)
		#expect(group.members.map(\.clip) == clips)
		#expect(fileCount(dir, "blobs") == 1 && fileCount(dir, "thumbs") == 1 && fileCount(dir, "trash") == 4)
		try await expectNonmemberUnchanged()
		try await store.removeOrphans()
		#expect(fileCount(dir, "trash") == 4)
		#expect(await store.cleanupPending == false)
		#expect(try await store.ftsKeys() == [other.key])
		await store.failTransaction(commit: .afterEffect)
		let restored = try await store.restoreGroup(group.token)
		try #require(restored.map(\.key) == keys)
		try await expectNonmemberUnchanged()
		let previousMax = try #require(clips.map(\.generation).max())
		#expect(restored[0].generation > previousMax && restored[1].generation > restored[0].generation)
		for (before, after) in zip(clips, restored) {
			var expected = before; expected.generation = after.generation
			#expect(after == expected)
			let thumb = try #require(await store.thumbnail(for: after.key))
			#expect(try Data(contentsOf: thumb) == Data([before.key == keys[0] ? 2 : 1]))
			#expect(try await store.items(for: after.key) == text(before.title).items)
		}
		#expect(try await store.search("group").sorted() == keys.sorted())
		#expect(fileCount(dir, "trash") == 0)
		await #expect(throws: StoreError.undoExpired) { try await store.restoreGroup(group.token) }
	}

	@Test func groupLargerThanBindLimitDeletesFTSOnceAndRestoresInCaptureOrder() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		try seedSQLRows(dir, count: 120)
		try editSQL(dir, "INSERT INTO meta VALUES ('generation',120)")
		let keys = (0..<45).reversed().map { "key-\($0)" }
		for key in keys { try ClipStore.encode(text(key).items).write(to: dir.appendingPathComponent("blobs/\(key).plist")) }
		await store.limitSQLVariables(20)
		await store.resetWriteCount()
		await store.resetReadCounts()
		await store.failTransaction(commit: .afterEffect)
		let group = try await store.deleteGroup(keys)
		// Independent of group size: no DELETE on unindexed FTS per member.
		#expect(await store.writeStatementCount == 2)
		// Three readbacks (prior, expected, persisted), each with at most one pass over 120 FTS rows.
		let rowBudget = 3 * 120 + 3 * keys.count + 6
		#expect(await store.steppedReadRowCount <= rowBudget)
		#expect(Set(try await store.ftsKeys()) == Set((45..<120).map { "key-\($0)" }))
		await store.resetReadCounts()
		await store.failTransaction(commit: .afterEffect)
		let restored = try await store.restoreGroup(group.token)
		#expect(await store.steppedReadRowCount <= rowBudget)
		#expect(restored.map(\.key) == keys)
		#expect(Set(restored.map(\.generation)).count == keys.count)
		#expect(try await store.ftsKeys().count == 120)
	}

	@Test(arguments: [false, true])
	func secondMemberFailureRollsBackSQLAndKeepsAuthoritativeFiles(restoring: Bool) async throws {
		let faulty = FaultyFiles()
		let (store, dir) = try tempStore(files: faulty); defer { try? FileManager.default.removeItem(at: dir) }
		let keys = try await pair(store).map(\.key)
		let group = restoring ? try await store.deleteGroup(keys) : nil
		let before = try await store.sqlState(nil)
		let files = try dataFiles(dir)
		func perform() async throws {
			if let group { _ = try await store.restoreGroup(group.token) }
			else { _ = try await store.deleteGroup(keys) }
		}
		faulty.failCopyContaining = keys[1]
		await #expect(throws: (any Error).self) { try await perform() }
		#expect(try dataFiles(dir) == files)
		#expect(try await store.sqlState(nil) == before)
		let event = restoring ? "INSERT" : "DELETE", row = restoring ? "new" : "old"
		// IGNORE suppresses one mutation without a SQLite error: row counts must still prove completion.
		try editSQL(dir, "CREATE TRIGGER skip_member BEFORE \(event) ON clips WHEN \(row).id='\(keys[1])' BEGIN SELECT RAISE(IGNORE); END;")
		await #expect(throws: StoreError.self) { try await perform() }
		#expect(try dataFiles(dir) == files)
		#expect(try await store.sqlState(nil) == before)
		try editSQL(dir, "DROP TRIGGER skip_member")
		try await perform()
	}

	@Test(arguments: [false, true])
	func beforeEffectWithConfirmedRollbackPreservesBothMembersAndUsableUndo(restoring: Bool) async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let clips = try await pair(store), keys = clips.map(\.key)
		// For delete failure, a previously issued disjoint handle must also stay usable.
		let priorKeys = restoring ? keys : try await pair(store, startingAt: 3).map(\.key)
		let prior = try await store.deleteGroup(priorKeys)
		let state = try await store.sqlState(nil), files = try dataFiles(dir)
		await store.failTransaction(commit: .beforeEffect)
		if restoring { await #expect(throws: StoreError.self) { try await store.restoreGroup(prior.token) } }
		else { await #expect(throws: StoreError.self) { try await store.deleteGroup(keys) } }
		#expect(await store.recoveryRequired == false)
		#expect(try await store.sqlState(nil) == state) // All rows, FTS entries and the generation counter.
		#expect(try dataFiles(dir) == files) // No staged destinations left behind.
		#expect(try await store.restoreGroup(prior.token).map(\.key) == priorKeys)
		if !restoring {
			let retry = try await store.deleteGroup(keys)
			#expect(retry.issuedSequence == prior.issuedSequence + 1)
			#expect(try await store.restoreGroup(retry.token).map(\.key) == keys)
		}
		for clip in clips { #expect(try await store.items(for: clip.key) == text(clip.title).items) }
	}

	@Test(arguments: [false, true], [false, true])
	func groupUnknownOutcomePreservesEveryCopyAndFreezesBothAPIs(restoring: Bool, failedRollback: Bool) async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let keys = try await pair(store).map(\.key), live = try dataFiles(dir)
		let group = restoring ? try await store.deleteGroup(keys) : nil
		let before = try dataFiles(dir)
		await store.failTransaction(commit: failedRollback ? .beforeEffect : .afterEffect, rollback: failedRollback, readback: !failedRollback)
		if let group { await #expect(throws: StoreError.outcomeUnknown) { try await store.restoreGroup(group.token) } }
		else { await #expect(throws: StoreError.outcomeUnknown) { try await store.deleteGroup(keys) } }
		#expect(await store.recoveryRequired)
		let frozen = try dataFiles(dir)
		try #require(frozen.count == 8 && before.allSatisfy { frozen[$0.key] == $0.value })
		for (url, bytes) in live {
			let key = url.deletingPathExtension().lastPathComponent
			let copies = frozen.filter { $0.key.deletingLastPathComponent().lastPathComponent == "trash"
				&& $0.key.lastPathComponent.hasPrefix("\(key).") && $0.key.pathExtension == url.pathExtension }
			#expect(frozen[url] == bytes && Array(copies.values) == [bytes])
		}
		await #expect(throws: StoreError.outcomeUnknown) { try await store.restoreGroup(group?.token ?? UUID()) }
		await #expect(throws: StoreError.outcomeUnknown) { try await store.deleteGroup(keys) }
		await #expect(throws: StoreError.outcomeUnknown) { try await store.recent() }
		await #expect(throws: StoreError.outcomeUnknown) { try await store.removeOrphans() }
		if let group { await store.invalidateGroup(group.token) }
		await store.emptyTrash()
		#expect(try dataFiles(dir) == frozen)
	}

	@Test func restorePreflightsEveryMemberBeforeTouchingDestinations() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let keys = try await pair(store).map(\.key), group = try await store.deleteGroup(keys)
		let last = group.members[1], url = await store.snapshotURL(last, "png")
		let image = try Data(contentsOf: url)
		try FileManager.default.removeItem(at: url)
		let calls = files.mutationCalls
		await #expect(throws: StoreError.missingThumbnail) { try await store.restoreGroup(group.token) }
		#expect(files.mutationCalls == calls)
		try image.write(to: url)
		try await store.seedRows([last.clip])
		await #expect(throws: StoreError.alreadyExists) { try await store.restoreGroup(group.token) }
		#expect(files.mutationCalls == calls)
		try editSQL(dir, "DELETE FROM clips WHERE id='\(keys[1])'; DELETE FROM clips_fts WHERE id='\(keys[1])'")
		#expect(try await store.restoreGroup(group.token).map(\.key) == keys)
	}

	@Test(arguments: [0, 1])
	func recopyOfEitherMemberExpiresOnlyItsGroup(member: Int) async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let clips = try await pair(store), group = try await store.deleteGroup(clips.map(\.key))
		let disjoint = try await pair(store, startingAt: 3), later = try await store.deleteGroup(disjoint.map(\.key))
		try #require(later.issuedSequence > group.issuedSequence)
		let recopy = text(clips[member].title)
		try await store.rejectNewRows(true)
		await #expect(throws: StoreError.self) { try await store.insert(recopy) }
		#expect(fileCount(dir, "trash") == 8)
		try await store.rejectNewRows(false)
		let (back, _) = try await store.insert(recopy)
		await #expect(throws: StoreError.undoExpired) { try await store.restoreGroup(group.token) }
		#expect(try await store.recent() == [back])
		#expect(try await store.ftsKeys() == [back.key])
		#expect(try await store.items(for: back.key) == recopy.items)
		#expect(fileCount(dir, "trash") == 4)
		#expect(try await store.restoreGroup(later.token).map(\.key) == disjoint.map(\.key))
		for (i, clip) in disjoint.enumerated() {
			#expect(try await store.items(for: clip.key) == text(clip.title).items)
			let thumb = try #require(await store.thumbnail(for: clip.key))
			#expect(try Data(contentsOf: thumb) == Data([UInt8(3 + i)]))
		}
		#expect(fileCount(dir, "trash") == 0)
	}

	@Test func eraseExpiresTheWholeGroupAndRemovesItsSnapshots() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let keys = try await pair(store).map(\.key), group = try await store.deleteGroup(keys)
		try #require(fileCount(dir, "trash") == 4)
		try await store.eraseAll()
		await #expect(throws: StoreError.undoExpired) { try await store.restoreGroup(group.token) }
		#expect(try await store.recent().isEmpty)
		#expect(try await store.ftsKeys().isEmpty)
		#expect(try dataFiles(dir).isEmpty)
	}

	@Test(arguments: [false, true])
	func cleanDeferredExpiryRetiresWithoutIOOrWarning(byCutoff: Bool) async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let clips = try await pair(store), old = try await store.deleteGroup(clips.map(\.key))
		let retiredFiles = try dataFiles(dir)
		let (next, _) = try await store.insert(text("later")), later = try await store.deleteGroup([next.key])
		let before = try dataFiles(dir), calls = files.mutationCalls, lists = files.listCalls, reads = files.readCalls
		try #require(await store.cleanupPending == false)
		await store.resetReadCounts(); await store.resetWriteCount()
		let receipt = byCutoff ? await store.emptyTrash(through: old.issuedSequence, deferCleanup: true)
			: await store.invalidateGroup(old.token, deferCleanup: true)
		let retired = try #require(receipt)
		#expect(await store.cleanupPending == false)
		#expect(await store.readStatementCount == 0)
		#expect(await store.writeStatementCount == 0)
		#expect(files.mutationCalls == calls && files.listCalls == lists && files.readCalls == reads)
		#expect(try dataFiles(dir) == before)
		await #expect(throws: StoreError.undoExpired) { try await store.restoreGroup(old.token) }
		#expect(await store.emptyTrash(through: old.issuedSequence, deferCleanup: true) == nil)
		#expect(await store.invalidateGroup(old.token, deferCleanup: true) == nil)

		// Before the callback runs, one old key is live again and the other is owned by a new undo.
		let current = try await pair(store), replacement = try await store.deleteGroup([current[1].key])
		let rolledOver = try dataFiles(dir), keep = rolledOver.filter { retiredFiles[$0.key] == nil }
		try #require(retiredFiles.count == 4 && later.issuedSequence > old.issuedSequence)
		await store.cleanRetiredSnapshots(retired)
		#expect(try dataFiles(dir) == keep)
		#expect(await store.cleanupPending == false)
		#expect(try await store.fetch(current[0].key) == current[0])
		#expect(try await store.restoreGroup(replacement.token).map(\.key) == [current[1].key])
		#expect(try await store.restoreGroup(later.token).map(\.key) == [next.key])
	}

	@Test(arguments: [false, true])
	func onlyRealRetiredCleanupFailuresSetDebt(unreadable: Bool) async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let keys = try await pair(store).map(\.key), old = try await store.deleteGroup(keys)
		let retired = try #require(await store.invalidateGroup(old.token, deferCleanup: true))
		#expect(await store.cleanupPending == false)
		if unreadable { await store.failNextStep() } else { files.failRemoveContaining = ".plist" }
		await store.cleanRetiredSnapshots(retired)
		#expect(fileCount(dir, "trash") == (unreadable ? 4 : 1))
		#expect(await store.cleanupPending)
		await store.cleanRetiredSnapshots(retired)
		#expect(fileCount(dir, "trash") == 0)
		#expect(await store.cleanupPending) // A targeted retry cannot clear a pre-existing warning.
		try await store.removeOrphans()
		#expect(await store.cleanupPending == false)
	}

	@Test func retiredReceiptsAreInstanceScopedAndInertDuringRecovery() async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let keys = try await pair(store).map(\.key), old = try await store.deleteGroup(keys)
		let retired = try #require(await store.emptyTrash(deferCleanup: true))
		let before = try dataFiles(dir)
		do {
			let other = try ClipStore(directory: dir, files: files)
			let calls = files.mutationCalls
			await other.cleanRetiredSnapshots(retired)
			#expect(files.mutationCalls == calls)
			#expect(try dataFiles(dir) == before)
		}
		let (clip, _) = try await store.insert(text("live again")), later = try await store.deleteGroup([clip.key])
		await store.failTransaction(commit: .afterEffect, readback: true)
		await #expect(throws: StoreError.outcomeUnknown) { try await store.restoreGroup(later.token) }
		let frozen = try dataFiles(dir), calls = files.mutationCalls
		await store.cleanRetiredSnapshots(retired)
		#expect(await store.emptyTrash(deferCleanup: true) == nil)
		#expect(await store.invalidateGroup(later.token, deferCleanup: true) == nil)
		#expect(files.mutationCalls == calls)
		#expect(before.count == old.members.count * 2 && before.allSatisfy { frozen[$0.key] == $0.value })
		#expect(try dataFiles(dir) == frozen)
	}

	@Test(arguments: [false, true])
	func immediateExpiryReturnsNoCleanupWork(byCutoff: Bool) async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let keys = try await pair(store).map(\.key), old = try await store.deleteGroup(keys)
		let receipt = byCutoff ? await store.emptyTrash(through: old.issuedSequence) : await store.invalidateGroup(old.token)
		#expect(receipt == nil)
		#expect(try dataFiles(dir).isEmpty)
	}

	@Test(arguments: [false, true])
	func deferredExpiryDoesNotWriteEvenWithLegacyDebtAndPreservesNewerGroup(byCutoff: Bool) async throws {
		let files = FaultyFiles()
		let (store, dir) = try tempStore(files: files); defer { try? FileManager.default.removeItem(at: dir) }
		let keys = try await pair(store).map(\.key), old = try await store.deleteGroup(keys)
		let (next, _) = try await store.insert(text("next")), later = try await store.deleteGroup([next.key])
		#expect(later.issuedSequence > old.issuedSequence)
		let draft = text("live legacy"), (legacy, _) = try await store.insert(draft)
		let home = await store.blobURL(legacy.key), source = await store.trashURL(legacy.key, "plist")
		try FileManager.default.moveItem(at: home, to: source)
		#expect(try await store.items(for: legacy.key) == draft.items)
		try #require(await store.cleanupPending)
		let before = try dataFiles(dir), calls = files.mutationCalls, lists = files.listCalls
		await store.resetWriteCount()
		let receipt = byCutoff ? await store.emptyTrash(through: old.issuedSequence, deferCleanup: true)
			: await store.invalidateGroup(old.token, deferCleanup: true)
		let retired = try #require(receipt)
		#expect(files.mutationCalls == calls && files.listCalls == lists)
		#expect(await store.writeStatementCount == 0)
		#expect(try dataFiles(dir) == before)
		await #expect(throws: StoreError.undoExpired) { try await store.restoreGroup(old.token) }
		await store.cleanRetiredSnapshots(retired)
		#expect(await store.cleanupPending)
		#expect(files.listCalls == lists)
		#expect(!FileManager.default.fileExists(atPath: home.path))
		#expect(try Data(contentsOf: source) == ClipStore.encode(draft.items))
		#expect(fileCount(dir, "trash") == 2) // The live legacy source and later undo, only.
		// A failed cleanup must not unlink the legacy source, or a snapshot owned by the later group.
		files.failCopyContaining = legacy.key
		try await store.removeOrphans()
		#expect(await store.cleanupPending)
		#expect(try Data(contentsOf: source) == ClipStore.encode(draft.items))
		try await store.removeOrphans()
		#expect(try await store.items(for: legacy.key) == draft.items)
		#expect(fileCount(dir, "trash") == 1)
		#expect(try await store.restoreGroup(later.token).map(\.key) == [next.key])
		#expect(await store.cleanupPending == false)
	}
}
