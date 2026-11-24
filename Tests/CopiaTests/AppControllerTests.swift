import Testing
import AppKit
import Synchronization
import CopiaCore
@testable import CopiaUI
@testable import CopiaApp
@testable import CopiaStore
@testable import CopiaSystem

/// A login item stand-in that records calls and can fail or require approval.
@MainActor
final class FakeLogin: LoginService {
	var status: LoginStatus = .disabled
	var calls: [String] = []
	var fail = false
	func register() throws {
		calls.append("register")
		if fail { throw CocoaError(.featureUnsupported) }
		if status != .requiresApproval { status = .enabled }
	}
	func unregister() throws {
		calls.append("unregister")
		if fail { throw CocoaError(.featureUnsupported) }
		status = .disabled
	}
}

/// Holds one snapshot copy so the main actor can close the strip while delete is running.
final class PausedSnapshotFiles: FileOps, Sendable {
	private let live = LiveFileOps()
	private let state = Mutex((pause: true, entered: false))
	private let release = DispatchSemaphore(value: 0)
	var entered: Bool { state.withLock { $0.entered } }
	func resume() { release.signal() }
	func write(_ data: Data, to url: URL) throws { try live.write(data, to: url) }
	func copy(_ from: URL, to: URL) throws {
		let pause = state.withLock { state in
			guard state.pause else { return false }
			state.pause = false; state.entered = true
			return true
		}
		if pause, release.wait(timeout: .now() + 5) == .timedOut { throw CocoaError(.fileWriteUnknown) }
		try live.copy(from, to: to)
	}
	func remove(_ url: URL) throws { try live.remove(url) }
	func exists(_ url: URL) -> Bool { live.exists(url) }
	func list(_ directory: URL) throws -> [URL] { try live.list(directory) }
}

/// A controller over a temporary store, a fake pasteboard and a private defaults suite. Nothing reaches the system clipboard.
@MainActor
final class AppRig {
	let dir: URL
	/// Only a rig that made its own directory removes it; rigs sharing one (a relaunch) leave it to the test.
	private let ownsDirectory: Bool
	let suite = "copia-tests-\(UUID().uuidString)"
	let defaults: UserDefaults
	let board = NSPasteboard.withUniqueName()
	let login = FakeLogin()
	let links = CountingLinks()
	let thumbs = CountingThumbnails()
	var permissions = PermissionState(pasteboard: .unset)
	let controller: AppController

	init(dir shared: URL? = nil, storageFiles: any FileOps = LiveFileOps()) throws {
		dir = shared ?? FileManager.default.temporaryDirectory.appendingPathComponent("copia-app-\(UUID().uuidString)")
		ownsDirectory = shared == nil
		defaults = UserDefaults(suiteName: suite)!
		weak var rig: AppRig?
		// One private board for capture and Copia's writes, as the live app uses the general pasteboard for both.
		controller = try AppController(directory: dir, defaults: defaults, pasteboard: GeneralPasteboard(board), writerBoard: board, login: login,
			permissions: { rig?.permissions ?? PermissionState(pasteboard: .unset) },
			links: links, files: thumbs, storageFiles: storageFiles)
		rig = self
		controller.model.animator = .immediate
	}

	/// Launches as the app does, without onboarding, menu or hotkeys. Call `stop()` when done.
	func launch() async { await controller.start(showOnboarding: false, menuAndHotkeys: false) }
	func stop() { controller.watcher.stop() }

	func copy(_ text: String) async throws {
		let draft = ClipDraft(items: [PasteboardItemData([(PasteboardTypes.string, Data(text.utf8))])], copiedAt: .now)
		try await controller.store.insert(draft)
		await controller.reload()
	}

	/// Another app copies `text` to the board.
	func copyElsewhere(_ text: String, extraTypes: [String] = []) {
		board.clearContents()
		let item = NSPasteboardItem()
		item.setString(text, forType: .string)
		for type in extraTypes { item.setData(Data(), forType: .init(type)) }
		board.writeObjects([item])
	}

	func titles() -> [String] { controller.model.clips.map(\.text) }

	func fileCount(_ sub: String) -> Int {
		(try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path).count) ?? 0
	}

	isolated deinit {
		board.releaseGlobally()
		if ownsDirectory { try? FileManager.default.removeItem(at: dir) }
		UserDefaults.standard.removePersistentDomain(forName: suite)
	}
}

/// A store directory several rigs share, as one install across relaunches. Removed by the test.
func sharedStoreDirectory() -> URL {
	FileManager.default.temporaryDirectory.appendingPathComponent("copia-app-\(UUID().uuidString)")
}

/// Polls `condition` for up to two seconds.
@MainActor
func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
	for _ in 0..<200 {
		if try await condition() { return true }
		try? await Task.sleep(for: .milliseconds(10))
	}
	return try await condition()
}

extension WindowTests {
	@MainActor @Suite struct AppControllerTests {}
}

extension WindowTests.AppControllerTests {
	@Test func anInsertWhileOpenKeepsTheSelectionAndARecopyMovesToTheFront() async throws {
		let r = try AppRig()
		try await r.copy("one"); try await r.copy("two"); try await r.copy("three")
		r.controller.model.open()
		r.controller.model.select(r.controller.model.clips[1].id)
		let selected = r.controller.model.selectedID
		try await r.copy("four")
		#expect(r.titles() == ["four", "three", "two", "one"])
		#expect(r.controller.model.selectedID == selected)
		try await r.copy("one")
		#expect(r.titles().first == "one")
	}

	@Test func deleteAndUndoMatchTheStore() async throws {
		let r = try AppRig()
		try await r.copy("a"); try await r.copy("b"); try await r.copy("c")
		r.controller.model.open()
		r.controller.model.select(r.controller.model.clips[1].id)
		await r.controller.model.deleteSelected()
		#expect(r.titles() == ["c", "a"])
		#expect(try await r.controller.store.recent().map(\.title) == ["c", "a"])
		#expect(r.controller.model.selectedID == r.controller.model.clips[1].id)
		await r.controller.model.undo()
		#expect(r.titles() == ["c", "b", "a"])
		#expect(try await r.controller.store.recent().map(\.title) == ["c", "b", "a"])
		#expect(r.controller.model.selectedID == r.controller.model.clips[1].id)
	}

	@Test func aRecopyOrEraseEndsUndoWithoutAPhantomCard() async throws {
		let r = try AppRig()
		try await r.copy("gone"); try await r.copy("other")
		r.controller.model.open()
		r.controller.model.select(r.controller.model.clips[1].id)
		await r.controller.model.deleteSelected()
		try await r.copy("gone")
		#expect(!r.controller.model.canUndo)
		r.controller.model.select(r.controller.model.clips[0].id)
		await r.controller.model.deleteSelected()
		await r.controller.erase()
		#expect(!r.controller.model.canUndo)
		await r.controller.model.undo()
		#expect(r.controller.model.clips.isEmpty)
	}

	/// Closing the strip ends undo and empties trash/.
	@Test func deleteThenCloseEndsUndoAndEmptiesTrash() async throws {
		let r = try AppRig()
		try await r.copy("gone"); try await r.copy("kept")
		r.controller.model.open()
		r.controller.model.select(r.controller.model.clips[1].id)
		await r.controller.model.deleteSelected()
		#expect(r.controller.model.canUndo)
		#expect(r.fileCount("trash") == 1)
		r.controller.model.beginClose()
		#expect(!r.controller.model.canUndo)
		#expect(await eventually { r.fileCount("trash") == 0 })
		r.controller.model.open()
		await r.controller.model.undo()
		#expect(r.titles() == ["kept"])
		#expect(try await r.controller.store.recent().map(\.title) == ["kept"])
	}

	/// A relaunch over the same store ends the old session's undo and empties trash/.
	@Test func deleteThenRelaunchEndsUndoAndEmptiesTrash() async throws {
		let dir = sharedStoreDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
		let first = try AppRig(dir: dir)
		try await first.copy("gone"); try await first.copy("kept")
		first.controller.model.open()
		first.controller.model.select(first.controller.model.clips[1].id)
		await first.controller.model.deleteSelected()
		#expect(first.fileCount("trash") == 1)
		#expect(first.controller.model.canUndo)

		let second = try AppRig(dir: dir)
		await second.launch(); defer { second.stop() }
		#expect(second.fileCount("trash") == 0)
		#expect(!second.controller.model.canUndo)
		#expect(second.titles() == ["kept"])
		// The old session's undo now finds nothing to bring back and changes nothing.
		await first.controller.model.undo()
		#expect(try await second.controller.store.recent().map(\.title) == ["kept"])
		#expect(second.fileCount("blobs") == 1 && second.fileCount("trash") == 0)
	}

	/// Pending link and image clips get one new preview request at launch and reach a saved final state.
	@Test func launchResumesPendingPreviewsOnce() async throws {
		let dir = sharedStoreDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
		let png = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
			hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:]))
		let (link, image): (StoredClip, StoredClip) = try await {
			let seed = try ClipStore(directory: dir)
			let link = try await seed.insert(ClipDraft(items: [PasteboardItemData([(PasteboardTypes.string, Data("https://example.com/post".utf8))])], copiedAt: .now)).clip
			let image = try await seed.insert(ClipDraft(items: [PasteboardItemData([(PasteboardTypes.png, png)])], copiedAt: .now)).clip
			return (link, image)
		}()
		#expect(link.previewState == .pending && image.previewState == .pending)

		let r = try AppRig(dir: dir)
		await r.launch(); defer { r.stop() }
		#expect(try await eventually { try await r.controller.store.pending().isEmpty })
		#expect(r.links.calls == 1)
		#expect(r.controller.previewer.stats.decodes == 1)
		let reopened = try ClipStore(directory: dir)
		#expect(try await reopened.fetch(link.key)?.previewState == .okNoImage)
		#expect(try await reopened.fetch(link.key)?.title == "A title")
		#expect(try await reopened.fetch(image.key)?.previewState == .ok)
		#expect(await reopened.thumbnail(for: image.key) != nil)
	}

	/// A saved link preview with an image is reused after a relaunch with no network: no fetch, same title and image.
	@Test func aSavedLinkPreviewIsReusedOfflineAfterARelaunch() async throws {
		let dir = sharedStoreDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
		let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
		let link: StoredClip = try await {
			let seed = try ClipStore(directory: dir)
			let clip = try await seed.insert(ClipDraft(items: [PasteboardItemData([(PasteboardTypes.string, Data("https://example.com/post".utf8))])], copiedAt: .now)).clip
			try await seed.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Saved title", image: image)
			return clip
		}()

		let r = try AppRig(dir: dir)
		r.links.result = .failure(URLError(.notConnectedToInternet))
		await r.launch(); defer { r.stop() }
		let stored = try #require(try await r.controller.store.fetch(link.key))
		r.controller.previewer.generate(for: stored)
		await r.controller.previewer.resumePending()
		try await Task.sleep(for: .milliseconds(50))
		#expect(r.links.calls == 0)
		#expect(stored.previewState == .ok && stored.title == "Saved title")
		let card = try #require(r.controller.model.clips.first)
		#expect(card.text == "Saved title")
		guard case let .ready(url) = card.preview else { Issue.record("expected the saved image, got \(card.preview)"); return }
		#expect(try Data(contentsOf: url) == image)
	}

	@Test func aFailedEraseIsShownInSettings() async throws {
		let r = try AppRig()
		try await r.copy("kept")
		let blobs = r.dir.appendingPathComponent("blobs")
		try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blobs.path)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobs.path) }
		await r.controller.erase()
		#expect(r.controller.shell.eraseError != nil)
		#expect(r.titles().isEmpty)
	}

	/// A link saved with only its site icon shows that icon; without the file it falls back to the link glyph.
	@Test func aLinkWithOnlyASiteIconShowsIt() {
		let s = StoredClip(key: String(repeating: "ab", count: 32), kind: .link, title: "example.com", previewText: "", isCode: false, sourceBundle: nil,
			sourceName: nil, firstCopied: .now, lastCopied: .now, copyCount: 1, byteSize: 1, meta: "", colorHex: nil,
			url: "https://example.com", fileNames: [], previewState: .okNoImage, generation: 1)
		let icon = URL(fileURLWithPath: "/tmp/k.png")
		#expect(AppController.clip(from: s, thumbnail: icon).preview == .icon(icon))
		#expect(AppController.clip(from: s, thumbnail: nil).preview == .failed)
	}

	@Test func searchFindsTextBeyondTheCardPreview() async throws {
		let r = try AppRig()
		try await r.copy(String(repeating: "filler ", count: 200) + "needle")
		try await r.copy("other")
		r.controller.model.open()
		r.controller.model.query = "needle"
		await r.controller.model.searchStore()
		#expect(r.controller.model.visibleClips.count == 1)
	}

	@Test func retentionPrunesOnTheInjectedClockEveryHour() async throws {
		let r = try AppRig()
		try await r.copy("https://example.com/old")
		let clip = try #require(try await r.controller.store.recent().first)
		try await r.controller.store.setPreview(key: clip.key, generation: clip.generation, state: .ok, image: Data([1]))
		#expect(r.fileCount("blobs") == 1 && r.fileCount("thumbs") == 1)
		#expect(AppController.retentionInterval == 3_600)
		r.controller.now = { Date.now.addingTimeInterval(40 * 86_400) }
		await r.controller.retentionTick()
		#expect(r.titles().isEmpty)
		#expect(r.fileCount("blobs") == 0 && r.fileCount("thumbs") == 0)
		#expect(try await r.controller.store.ftsKeys().isEmpty)
	}

	@Test func recoveryStatusPausesCaptureWithoutChangingThePreference() async throws {
		let r = try AppRig()
		#expect(!r.controller.prefs.paused)
		r.controller.applyStorageStatus(cleanupPending: true, recoveryRequired: true)
		#expect(r.controller.shell.storageStatus == .recoveryRequired)
		#expect(r.controller.model.storageStatus == .recoveryRequired)
		#expect(r.controller.watcher.paused)
		#expect(!r.controller.prefs.paused)
		r.controller.togglePause()
		#expect(r.controller.watcher.paused)
		#expect(!r.controller.prefs.paused)
	}

	@Test func aStaleStatusRefreshCannotClearRecoveryBeforeRestart() throws {
		let r = try AppRig()
		r.controller.applyStorageStatus(cleanupPending: true, recoveryRequired: true)
		r.controller.applyStorageStatus(cleanupPending: false, recoveryRequired: false)
		#expect(r.controller.model.storageStatus == .recoveryRequired)
		#expect(r.controller.shell.storageStatus == .recoveryRequired)
		#expect(r.controller.watcher.paused)
	}

	@Test func reloadUsesOneConsistentSnapshotWithoutPerClipQueries() async throws {
		let r = try AppRig()
		for i in 0..<100 { try await r.copy("snapshot \(i)") }
		await r.controller.store.resetReadCounts()
		await r.controller.reload()
		#expect(r.titles().count == 100)
		// Includes status refresh: cached diagnostics must not add another history query.
		#expect(await r.controller.store.readStatementCount == 1)
		#expect(await r.controller.store.readRowCount == 100)
	}

	@Test func cleanupWarningReflectsVerifiedStoreStatus() throws {
		let r = try AppRig()
		r.controller.applyStorageStatus(cleanupPending: true, recoveryRequired: false)
		#expect(r.controller.shell.storageStatus == .cleanupPending)
		#expect(r.controller.model.storageStatus == .cleanupPending)
		r.controller.applyStorageStatus(cleanupPending: false, recoveryRequired: false)
		#expect(r.controller.shell.storageStatus == .ready)
		#expect(r.controller.model.storageStatus == .ready)
	}

	@Test func committedDeleteAndRestoreKeepCleanupWarningsVisible() async throws {
		let files = FaultyFiles(), r = try AppRig(storageFiles: files)
		try await r.copy("cleanup candidate")
		r.controller.model.open()
		files.failRemoveContaining = "blobs/"
		await r.controller.model.deleteSelected()
		#expect(r.titles().isEmpty)
		#expect(r.controller.model.canUndo)
		#expect(r.controller.model.storageStatus == .cleanupPending)
		#expect(r.controller.shell.storageStatus == .cleanupPending)
		files.failRemoveContaining = "trash/"
		await r.controller.store.failTransaction(commit: .afterEffect)
		await r.controller.model.undo()
		#expect(r.titles() == ["cleanup candidate"])
		#expect(!r.controller.model.canUndo)
		#expect(r.controller.model.toast == nil)
		#expect(r.controller.model.storageStatus == .cleanupPending)
		await r.controller.retentionTick()
		#expect(r.controller.shell.storageStatus == .ready)
		#expect(r.fileCount("trash") == 0)
	}

	@Test func unknownDeleteOutcomePausesCaptureAndPreservesVisibleState() async throws {
		let r = try AppRig()
		try await r.copy("unknown outcome")
		r.controller.model.open()
		await r.controller.store.failTransaction(commit: .beforeEffect, rollback: true)
		await r.controller.model.deleteSelected()
		#expect(r.titles() == ["unknown outcome"])
		#expect(r.controller.model.storageStatus == .recoveryRequired)
		#expect(r.controller.shell.storageStatus == .recoveryRequired)
		#expect(r.controller.watcher.paused)
		#expect(r.controller.model.toast == .error(StorageStatus.recoveryRequired.message))
		#expect(!r.controller.model.canUndo)
		await r.controller.erase()
		#expect(r.fileCount("blobs") == 1)
	}

	@Test func closeDoesNotExpireDeletionStartedAfterReopen() async throws {
		let r = try AppRig()
		try await r.copy("first"); try await r.copy("second")
		r.controller.model.open()
		r.controller.model.select(r.controller.model.clips[0].id)
		await r.controller.model.deleteSelected()
		r.controller.model.beginClose()
		r.controller.model.open()
		await r.controller.model.deleteSelected()
		#expect(r.controller.model.canUndo)
		await r.controller.model.undo()
		#expect(r.titles() == ["first"])
		#expect(!r.controller.model.canUndo)
	}

	@Test func deleteInFlightDuringCloseInvalidatesItsStoreTokenAfterReopen() async throws {
		let files = PausedSnapshotFiles(), r = try AppRig(storageFiles: files)
		defer { files.resume() }
		try await r.copy("in flight")
		r.controller.model.open()
		let deleting = Task { await r.controller.model.deleteSelected() }
		#expect(await eventually { files.entered })
		r.controller.model.beginClose()
		r.controller.model.open()
		files.resume()
		await deleting.value
		#expect(!r.controller.model.canUndo)
		#expect(r.titles().isEmpty)
		#expect(await eventually { r.fileCount("trash") == 0 })
		await r.controller.model.undo()
		#expect(try await r.controller.store.recent().isEmpty)
	}

	@Test func expiredUndoCallbackRemovesItsSnapshot() async throws {
		let r = try AppRig(), clock = ClockProbe()
		r.controller.model.clock = clock.clock
		try await r.copy("expires")
		r.controller.model.open()
		await r.controller.model.deleteSelected()
		#expect(r.fileCount("trash") == 1)
		clock.advance(by: .seconds(3))
		#expect(!r.controller.model.canUndo)
		#expect(await eventually { r.fileCount("trash") == 0 })
		r.controller.model.open()
		await r.controller.model.undo()
		#expect(r.titles().isEmpty)
	}

	@Test func groupedUndoRestoresPinsAndKeepsLaterCopies() async throws {
		let r = try AppRig(), model = r.controller.model
		try await r.copy("first member"); try await r.copy("second member")
		let pinned = try #require(model.clips.last?.id)
		try await model.actions.setPinned(pinned, true)
		model.open()
		model.selectAllResults()
		await model.deleteSelected()
		#expect(r.titles().isEmpty && model.canUndo)
		try await r.copy("later item")
		await model.undo()
		#expect(r.titles() == ["first member", "later item", "second member"])
		#expect(model.clips.first?.isPinned == true)
		#expect(try await r.controller.store.recent().map(\.title) == r.titles())
		#expect(!model.canUndo)
	}

	@Test func recopyOfOneGroupMemberNeverOverwritesTheNewCopy() async throws {
		let r = try AppRig(), model = r.controller.model
		try await r.copy("red"); try await r.copy("blue")
		model.open(); model.selectAllResults()
		await model.deleteSelected()
		try await r.copy("red")
		#expect(!model.canUndo)
		await model.undo()
		#expect(r.titles() == ["red"])
		#expect(try await r.controller.store.recent().map(\.title) == ["red"])
	}

	@Test func activationWithUndoPendingOnlyCopiesAndReclaimsSnapshotsWithoutAWarning() async throws {
		let r = try AppRig(), model = r.controller.model, clock = ClockProbe()
		var cleanupScheduled = false
		model.clock = ToastClock { delay, fire in
			if !model.cardsMounted { cleanupScheduled = true }
			return clock.clock.after(delay, fire)
		}
		try await r.copy("one"); try await r.copy("two")
		model.open()
		model.select(try #require(model.clips.first { $0.text == "two" }?.id))
		await model.deleteSelected()
		let id = try #require(model.selectedID)
		let before = try FileManager.default.subpathsOfDirectory(atPath: r.dir.path).sorted()
		await model.copy(id: id, plain: false, dismiss: true)
		#expect(r.board.string(forType: .string) == "one")
		#expect(!model.cardsMounted && !model.canUndo)
		try #require(await eventually { cleanupScheduled })
		#expect(await r.controller.store.cleanupPending == false)
		#expect(model.storageStatus == .ready && r.controller.shell.storageStatus == .ready)
		#expect(try FileManager.default.subpathsOfDirectory(atPath: r.dir.path).sorted() == before)
		clock.advance(by: StripModel.toastLifetime)
		#expect(await eventually { r.fileCount("trash") == 0 })
		#expect(await r.controller.store.cleanupPending == false)
		#expect(model.storageStatus == .ready && r.controller.shell.storageStatus == .ready)
	}

	@Test func writingAFileReferenceDoesNotMaterializeItsContents() async throws {
		let r = try AppRig()
		let ref = r.dir.appendingPathComponent("never-created.pdf")
		let bytes = Data(ref.absoluteString.utf8)
		let clip = try await r.controller.store.insert(ClipDraft(items: [PasteboardItemData([(PasteboardTypes.fileURL, bytes)])], copiedAt: .now)).clip
		await r.controller.reload()
		let id = ClipDraft.uuid(forKey: clip.key)
		let before = try FileManager.default.subpathsOfDirectory(atPath: r.dir.path).sorted()
		try await r.controller.model.actions.write(id, false)
		#expect(r.board.pasteboardItems?.first?.data(forType: .fileURL) == bytes)
		#expect(r.board.types?.contains(.init(PasteboardTypes.marker)) == true)
		#expect(try FileManager.default.subpathsOfDirectory(atPath: r.dir.path).sorted() == before)
		#expect(!FileManager.default.fileExists(atPath: ref.path))
	}

	@Test func missingCardCannotReportASuccessfulCopy() async throws {
		let r = try AppRig(), count = r.board.changeCount
		await #expect(throws: (any Error).self) { try await r.controller.model.actions.write(UUID(), false) }
		#expect(r.board.changeCount == count)
	}

	@Test func hidingMenuIconPersistsWithoutPausingTheWatcher() async throws {
		let r = try AppRig()
		await r.launch(); defer { r.stop() }
		#expect(r.controller.shell.showMenuBarIcon)
		r.controller.shell.setShowMenuBarIcon(false)
		#expect(!Preferences(defaults: r.defaults).showMenuBarIcon)
		#expect(!r.controller.shell.showMenuBarIcon && !r.controller.watcher.paused)
		r.copyElsewhere("captured without a status icon")
		r.controller.watcher.tick()
		#expect(await eventually { r.titles().contains("captured without a status icon") })
		r.controller.shell.togglePause()
		#expect(r.controller.watcher.paused)
		r.controller.shell.togglePause()
		#expect(!r.controller.watcher.paused)
		r.controller.shell.setShowMenuBarIcon(true)
		#expect(Preferences(defaults: r.defaults).showMenuBarIcon)
	}

	@Test func settingsPersist() throws {
		let suite = "copia-tests-\(UUID().uuidString)"
		defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
		let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
		prefs.retention = .week
		prefs.ignoredApps = ["com.example.Secret"]
		prefs.paused = true
		prefs.onboarded = true
		let again = Preferences(defaults: UserDefaults(suiteName: suite)!)
		#expect(again.retention == .week)
		#expect(again.ignoredApps == ["com.example.Secret"])
		#expect(again.paused && again.onboarded)
	}

	@Test func settingsOpenAsOneToolbarTabbedWindow() throws {
		let r = try AppRig()
		let window = r.controller.settings()
		let tabs = try #require(window.contentViewController as? NSTabViewController)
		#expect(tabs.tabStyle == .toolbar)
		#expect(tabs.tabViewItems.map(\.label) == ["General", "Shortcuts", "Privacy", "About"])
		#expect(r.controller.settings() === window)
	}

	@Test func loginItemCoversRegisterUnregisterApprovalAndError() throws {
		let r = try AppRig()
		r.controller.shell.setLogin(true)
		#expect(r.controller.shell.login == .enabled)
		r.controller.shell.setLogin(false)
		#expect(r.controller.shell.login == .disabled)
		r.login.status = .requiresApproval
		r.controller.shell.setLogin(true)
		#expect(r.controller.shell.login == .requiresApproval)
		r.login.fail = true
		r.controller.shell.setLogin(true)
		if case .error = r.controller.shell.login {} else { Issue.record("expected an error state") }
		#expect(r.login.calls == ["register", "unregister", "register", "register"])
	}

	@Test func onboardingFollowsPermissionChangesLive() throws {
		let r = try AppRig()
		for pasteboard in [PermissionState.Pasteboard.unset, .ask, .allow, .deny] {
			r.permissions = PermissionState(pasteboard: pasteboard)
			r.controller.refreshPermissions()
			#expect(r.controller.shell.permissions == r.permissions)
		}
	}

	@Test func anIgnoredAppEditChangesTheNextCapture() throws {
		let r = try AppRig()
		r.controller.shell.setIgnoredApps(["com.example.Editor"])
		#expect(r.controller.watcherIgnoredApps == ["com.example.Editor"])
	}
}

/// #26 at the app level: what the clipboard holds decides where the lens opens, and ⎋ never overwrites a newer copy.
extension WindowTests.AppControllerTests {
	@Test func theLensOpensOnACapturedCopyAndOnTheNewestCardWhenTheClipboardIsUnknown() async throws {
		let r = try AppRig(); await r.launch(); defer { r.stop() }
		let model = r.controller.model, panel = r.controller.panel
		panel.alphaValue = 0
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("older")
		r.copyElsewhere("captured")
		r.controller.watcher.tick()
		try #require(await eventually { model.clips.first?.text == "captured" })
		try await r.copy("newest, not on the clipboard")
		r.controller.toggleHistory()
		#expect(model.clips.first { $0.id == model.selectedID }?.text == "captured")
		#expect(model.lensOnClipboard)
		model.beginClose(); try #require(await eventually { !model.cardsMounted })
		r.copyElsewhere("secret", extraTypes: ["org.nspasteboard.ConcealedType"])
		r.controller.watcher.tick()
		r.controller.toggleHistory()
		#expect(model.clips.first { $0.id == model.selectedID }?.text == "newest, not on the clipboard")
		#expect(!model.lensOnClipboard && model.clipboard == nil)
	}

	@Test func escapeNeverRestoresOverACopyMadeElsewhereDuringTheRestore() async throws {
		let r = try AppRig(); await r.launch(); defer { r.stop() }
		let model = r.controller.model, panel = r.controller.panel
		panel.alphaValue = 0
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("second")
		r.copyElsewhere("first")
		r.controller.watcher.tick()
		try #require(await eventually { model.clips.first?.text == "first" })
		r.controller.toggleHistory()
		try #require(model.lensOnClipboard)
		model.browse(1)
		try #require(await eventually { r.board.string(forType: .string) == "second" })
		// Another app copies after the restore has read its payload, before Copia touches the pasteboard.
		r.controller.beforePasteboardWrite = { r.copyElsewhere("theirs") }
		model.escape()
		try await Task.sleep(for: .milliseconds(300))
		#expect(r.board.string(forType: .string) == "theirs", "the restore must not overwrite the newer copy")
	}

	@Test func aPickOverACopyMadeElsewhereJustBeforeTheWriteShowsCopied() async throws {
		let r = try AppRig(); await r.launch(); defer { r.stop() }
		let model = r.controller.model, panel = r.controller.panel
		panel.alphaValue = 0
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("second")
		r.copyElsewhere("first")
		r.controller.watcher.tick()
		try #require(await eventually { model.clips.first?.text == "first" })
		r.controller.toggleHistory()
		try #require(model.lensOnClipboard && model.restoreHint == nil)
		let first = try #require(model.clips.first { $0.text == "first" }).id
		// Another app copies after the watcher's last poll, right before Copia's pick clears the pasteboard.
		r.controller.beforePasteboardWrite = { r.copyElsewhere("theirs") }
		await model.copy(id: first, plain: false, dismiss: false)
		#expect(r.board.string(forType: .string) == "first", "a pick overwrites, as before")
		#expect(model.restoreHint == .copied, "the pick changed the clipboard back from the unseen copy")
	}

	@Test func theLensReopensOnCopiasOwnLastWriteIncludingPlainText() async throws {
		let r = try AppRig(); await r.launch(); defer { r.stop() }
		let model = r.controller.model, panel = r.controller.panel
		panel.alphaValue = 0
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("one"); try await r.copy("two"); try await r.copy("three")
		r.controller.toggleHistory()
		let one = try #require(model.clips.first { $0.text == "one" }).id
		await model.copy(id: one, plain: true, dismiss: true)
		try #require(await eventually { !model.cardsMounted })
		r.controller.watcher.tick()
		r.controller.toggleHistory()
		#expect(model.selectedID == one && model.lensOnClipboard)
		#expect(model.clipboard == ClipboardCard(id: one, plain: true))
	}

	@Test func aConcealedCopyWhileTheStripIsOpenEndsTheRestorePoint() async throws {
		let r = try AppRig(); await r.launch(); defer { r.stop() }
		let model = r.controller.model, panel = r.controller.panel
		panel.alphaValue = 0
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("second")
		r.copyElsewhere("first")
		r.controller.watcher.tick()
		try #require(await eventually { model.clips.first?.text == "first" })
		r.controller.toggleHistory()
		try #require(model.lensOnClipboard)
		r.copyElsewhere("secret", extraTypes: ["org.nspasteboard.ConcealedType"])
		r.controller.watcher.tick()
		#expect(!model.lensOnClipboard && model.committed == nil)
		model.browse(1)
		try #require(await eventually { r.board.string(forType: .string) == "second" })
		#expect(model.restoreHint == .unsaved)
		model.escape()
		try await Task.sleep(for: .milliseconds(300))
		#expect(r.board.string(forType: .string) == "second", "Copia never puts back a card over content it did not save")
	}

	@Test func aBrowseNeverOverwritesACopyMadeElsewhereBeforeTheNextPoll() async throws {
		let r = try AppRig(); await r.launch(); r.stop()
		let model = r.controller.model, panel = r.controller.panel
		panel.alphaValue = 0
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("second")
		r.copyElsewhere("first")
		r.controller.watcher.tick()
		try #require(await eventually { model.clips.first?.text == "first" })
		r.controller.toggleHistory()
		try #require(model.lensOnClipboard)
		// Another app copies a password; the half-second poll has not seen it yet.
		r.copyElsewhere("secret", extraTypes: ["org.nspasteboard.ConcealedType"])
		model.browse(1)
		try await Task.sleep(for: .milliseconds(400))
		#expect(r.board.string(forType: .string) == "secret", "the browse must not overwrite a copy it has not seen")
		#expect(model.committed == nil && !model.lensOnClipboard)
		model.escape()
		try await Task.sleep(for: .milliseconds(300))
		#expect(r.board.string(forType: .string) == "secret")
	}

	@Test func aCopyMadeBeforeOpeningNeverCancelsTheFirstArrow() async throws {
		let r = try AppRig(); await r.launch(); r.stop()
		let model = r.controller.model, panel = r.controller.panel
		panel.alphaValue = 0
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("older"); try await r.copy("newest")
		r.copyElsewhere("secret", extraTypes: ["org.nspasteboard.ConcealedType"])
		// Opened before the next poll: the strip opened on the secret, which Copia never saves.
		r.controller.toggleHistory()
		model.browse(1)
		#expect(await eventually { r.board.string(forType: .string) == "older" }, "the first arrow still copies")
	}

	@Test func aCopyMadeJustBeforeOpeningIsRestoredWhenSavedBeforeTheArrowCopies() async throws {
		let r = try AppRig(); await r.launch(); r.stop()
		let model = r.controller.model, panel = r.controller.panel, clock = ClockProbe()
		panel.alphaValue = 0
		model.clock = clock.clock
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("oldest"); try await r.copy("older")
		r.copyElsewhere("just copied")
		r.controller.toggleHistory()
		#expect(model.committed == nil, "opened before the poll: unknown")
		model.browse(1)
		// The poll saves the copy before the lens rests: it is what the clipboard held before browsing changed it.
		r.controller.watcher.tick()
		try #require(await eventually { model.committed != nil && model.clips.first { $0.id == model.committed?.id }?.text == "just copied" })
		clock.advance(by: StripModel.browseSettle)
		try #require(await eventually { r.board.string(forType: .string) == "oldest" })
		#expect(model.restoreHint == .restore)
		model.escape()
		#expect(await eventually { r.board.string(forType: .string) == "just copied" })
	}

	@Test func theChipAlwaysMatchesWhatEscapeDoesForACopyMadeJustBeforeOpening() async throws {
		let r = try AppRig(); await r.launch(); r.stop()
		let model = r.controller.model, panel = r.controller.panel, clock = ClockProbe()
		panel.alphaValue = 0
		model.clock = clock.clock
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("oldest"); try await r.copy("older")
		r.copyElsewhere("just copied")
		r.controller.toggleHistory()
		model.browse(1)
		// The arrow's own check finds the copy and saves it while its write runs: either may finish first.
		clock.advance(by: StripModel.browseSettle)
		try #require(await eventually { r.board.string(forType: .string) == "oldest" })
		try #require(await eventually { model.clips.contains { $0.text == "just copied" } })
		try await Task.sleep(for: .milliseconds(100))
		let hint = try #require(model.restoreHint)
		model.escape()
		try await Task.sleep(for: .milliseconds(300))
		#expect(r.board.string(forType: .string) == (hint == .restore ? "just copied" : "oldest"), "chip \(hint)")
	}

	@Test func aCopySeenWhileHiddenAndSavedAfterTheArrowCopiesIsStillTheRestorePoint() async throws {
		let r = try AppRig(); await r.launch(); r.stop()
		let model = r.controller.model, panel = r.controller.panel, clock = ClockProbe(), gate = WriteGate()
		panel.alphaValue = 0
		model.clock = clock.clock
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("oldest"); try await r.copy("older")
		// The poll sees and saves the copy while the strip is hidden; its callback is held before history reloads.
		r.controller.afterCaptureSaved = { await withCheckedContinuation { gate.waiting.append($0) } }
		r.copyElsewhere("just copied")
		r.controller.watcher.tick()
		try #require(await eventually { !gate.waiting.isEmpty })
		r.controller.afterCaptureSaved = {}
		// Opened on exactly that copy, before Copia knows its card.
		r.controller.toggleHistory()
		try #require(model.committed == nil)
		model.browse(1)
		clock.advance(by: StripModel.browseSettle)
		try #require(await eventually { r.board.string(forType: .string) == "oldest" })
		gate.release()
		try #require(await eventually { model.clips.contains { $0.text == "just copied" } && model.restoreHint == .restore },
			"hint \(String(describing: model.restoreHint)) committed \(String(describing: model.committed))")
		model.escape()
		#expect(await eventually { r.board.string(forType: .string) == "just copied" })
	}

	@Test func escapeNeverRestoresOverACopyMadeWhileCaptureWasPaused() async throws {
		let r = try AppRig(); await r.launch(); r.stop()
		let model = r.controller.model, panel = r.controller.panel
		panel.alphaValue = 0
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("second")
		r.copyElsewhere("first")
		r.controller.watcher.tick()
		try #require(await eventually { model.clips.first?.text == "first" })
		r.controller.toggleHistory()
		model.browse(1)
		try #require(await eventually { r.board.string(forType: .string) == "second" })
		r.controller.watcher.setPaused(true)
		r.copyElsewhere("secret", extraTypes: ["org.nspasteboard.ConcealedType"])
		r.controller.watcher.setPaused(false)
		model.escape()
		try await Task.sleep(for: .milliseconds(300))
		#expect(r.board.string(forType: .string) == "secret")
	}

	@Test func aDoubleClickAfterAnUnseenCopyWritesTheCardAgain() async throws {
		let r = try AppRig(); await r.launch(); r.stop()
		let model = r.controller.model, panel = r.controller.panel
		panel.alphaValue = 0
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("one"); try await r.copy("two")
		r.controller.toggleHistory()
		let one = try #require(model.clips.first { $0.text == "one" }).id
		await model.click(one, count: 1)
		try #require(r.board.string(forType: .string) == "one")
		r.copyElsewhere("theirs")
		await model.click(one, count: 2)
		#expect(r.board.string(forType: .string) == "one", "the closing click must put its card back")
		#expect(await eventually { model.clips.contains { $0.text == "theirs" } }, "the unseen copy is saved first")
	}

	@Test func losingKeyFocusThroughTheAppKeepsTheArrowedCard() async throws {
		let r = try AppRig(); await r.launch(); r.stop()
		let model = r.controller.model, panel = r.controller.panel
		panel.alphaValue = 0
		defer { model.beginClose(); panel.orderOut(nil) }
		try await r.copy("second")
		r.copyElsewhere("first")
		r.controller.watcher.tick()
		try #require(await eventually { model.clips.first?.text == "first" })
		r.controller.toggleHistory()
		panel.makeKey()
		try #require(await eventually { panel.isKeyWindow })
		model.browse(1)
		// Settings takes key before the lens rests, through the app's own observer.
		r.controller.openSettings()
		defer { r.controller.settings().orderOut(nil) }
		try #require(await eventually { !model.cardsMounted })
		#expect(await eventually { r.board.string(forType: .string) == "second" })
	}

}
