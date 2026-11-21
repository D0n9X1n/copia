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
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-app-\(UUID().uuidString)")
	let suite = "copia-tests-\(UUID().uuidString)"
	let defaults: UserDefaults
	let pasteboard = FakePasteboard()
	let login = FakeLogin()
	var permissions = PermissionState(accessibility: false, pasteboard: .unset)
	let controller: AppController

	init() throws {
		defaults = UserDefaults(suiteName: suite)!
		var rig: AppRig?
		controller = try AppController(directory: dir, defaults: defaults, pasteboard: pasteboard, login: login,
			permissions: { rig?.permissions ?? PermissionState(accessibility: false, pasteboard: .unset) },
			links: CountingLinks(), files: CountingThumbnails())
		rig = self
		controller.model.animator = .immediate
	}

	func copy(_ text: String) async throws {
		let draft = ClipDraft(items: [PasteboardItemData([(PasteboardTypes.string, Data(text.utf8))])], copiedAt: .now)
		try await controller.store.insert(draft)
		await controller.reload()
	}

	func titles() -> [String] { controller.model.clips.map(\.text) }

	deinit {
		try? FileManager.default.removeItem(at: dir)
		UserDefaults.standard.removePersistentDomain(forName: suite)
	}
}

@MainActor
@Suite(.serialized) struct AppControllerTests {
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
		#expect(AppController.retentionInterval == 3_600)
		r.controller.now = { Date.now.addingTimeInterval(40 * 86_400) }
		await r.controller.retentionTick()
		#expect(r.titles().isEmpty)
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
