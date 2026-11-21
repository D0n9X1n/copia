import Testing
import AppKit
import CopiaCore
import CopiaUI
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

/// A controller over a temporary store, a fake pasteboard and a private defaults suite. Nothing reaches the system clipboard.
@MainActor
final class AppRig {
	let dir: URL
	/// Only a rig that made its own directory removes it; rigs sharing one (a relaunch) leave it to the test.
	private let ownsDirectory: Bool
	let suite = "copia-tests-\(UUID().uuidString)"
	let defaults: UserDefaults
	let pasteboard = FakePasteboard()
	let login = FakeLogin()
	let links = CountingLinks()
	let thumbs = CountingThumbnails()
	var permissions = PermissionState(accessibility: false, pasteboard: .unset)
	let controller: AppController

	init(dir shared: URL? = nil) throws {
		dir = shared ?? FileManager.default.temporaryDirectory.appendingPathComponent("copia-app-\(UUID().uuidString)")
		ownsDirectory = shared == nil
		defaults = UserDefaults(suiteName: suite)!
		var rig: AppRig?
		controller = try AppController(directory: dir, defaults: defaults, pasteboard: pasteboard, login: login,
			permissions: { rig?.permissions ?? PermissionState(accessibility: false, pasteboard: .unset) },
			links: links, files: thumbs)
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

	func titles() -> [String] { controller.model.clips.map(\.text) }

	func fileCount(_ sub: String) -> Int {
		(try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path).count) ?? 0
	}

	deinit {
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

@MainActor
@Suite(.serialized) struct AppControllerTests {
	@Test func toggleStartsTheOpenAnimationBeforeReturningFromTheHiddenPosition() async throws {
		AXNode.enableInProcess()
		let r = try AppRig()
		try await r.copy("A fixture card")
		r.controller.panel.alphaValue = 0
		r.controller.visibleFrameOverride = CGRect(x: -6000, y: -6000, width: 900, height: 900)
		let previousKey = NSApp.keyWindow
		defer { r.controller.panel.orderOut(nil); previousKey?.makeKey() }
		var started = false
		r.controller.model.animator = Animator { event, change, completion in
			if event == .open {
				started = true
				#expect(r.controller.model.cardsMounted)
				#expect(!r.controller.model.appeared)
				let strip = AXNode(r.controller.panel.host).all.first { $0.label.hasPrefix("Clipboard history") }
				#expect(strip != nil)
				#expect((strip?.frame.maxY ?? .infinity) <= r.controller.panel.frame.minY + 0.5)
			}
			change()
			completion()
		}
		r.controller.toggleHistory()
		#expect(started)
		#expect(r.controller.model.appeared)
		// Break the test animator's capture of the rig.
		r.controller.model.animator = .immediate
	}

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
		try await r.copy("old")
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
		#expect(tabs.tabViewItems.map(\.label) == ["General", "Shortcuts", "Privacy"])
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
			for accessibility in [false, true] {
				r.permissions = PermissionState(accessibility: accessibility, pasteboard: pasteboard)
				r.controller.refreshPermissions()
				#expect(r.controller.shell.permissions == r.permissions)
			}
		}
	}

	@Test func anIgnoredAppEditChangesTheNextCapture() throws {
		let r = try AppRig()
		r.controller.shell.setIgnoredApps(["com.example.Editor"])
		#expect(r.controller.watcherIgnoredApps == ["com.example.Editor"])
	}
}
