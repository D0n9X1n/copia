import AppKit
import SwiftUI
import ServiceManagement
import KeyboardShortcuts
import CopiaCore
import CopiaStore
import CopiaSystem
import CopiaUI

/// Persisted preferences.
@MainActor
struct Preferences {
	let defaults: UserDefaults
	static let defaultIgnored = ["com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7"]

	var retention: Retention {
		get { defaults.string(forKey: "retention").flatMap(Retention.init(rawValue:)) ?? .month }
		nonmutating set { defaults.set(newValue.rawValue, forKey: "retention") }
	}
	var ignoredApps: [String] {
		get { defaults.stringArray(forKey: "ignoredApps") ?? Self.defaultIgnored }
		nonmutating set { defaults.set(newValue, forKey: "ignoredApps") }
	}
	var paused: Bool {
		get { defaults.bool(forKey: "paused") }
		nonmutating set { defaults.set(newValue, forKey: "paused") }
	}
	var onboarded: Bool {
		get { defaults.bool(forKey: "onboarded") }
		nonmutating set { defaults.set(newValue, forKey: "onboarded") }
	}
}

/// Launch at login. Tests supply a fake.
@MainActor
protocol LoginService: AnyObject {
	var status: LoginStatus { get }
	func register() throws
	func unregister() throws
}

@MainActor
final class MainAppLogin: LoginService {
	var status: LoginStatus {
		switch SMAppService.mainApp.status {
		case .enabled: .enabled
		case .requiresApproval: .requiresApproval
		default: .disabled
		}
	}
	func register() throws { try SMAppService.mainApp.register() }
	func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Wires the store, capture, previews and paste into the strip, menu bar, Settings and onboarding.
@MainActor
public final class AppController {
	public let model: StripModel
	public let panel = StripPanel()
	public let shell = ShellModel()
	let focus = SearchFocus()
	public let thumbnails = ThumbnailCache.shared
	public let store: ClipStore
	let watcher: PasteboardWatcher
	let previewer: Previewer
	let paster = Paster()
	let prefs: Preferences
	private var menu: MenuBarController?
	private var index = ClipIndex<DeletedClip>()
	private var reloads = 0
	private var lastDeliveredUndoSequence: UInt64 = 0
	private var target: NSRunningApplication?
	private var retentionTimer: Timer?
	private var settingsWindow: NSWindow?
	private var onboardingWindow: NSWindow?
	private var permissionPoll: Task<Void, Never>?
	/// Places the strip in this frame instead of the screen's visible frame (used by the benchmark).
	public var visibleFrameOverride: CGRect?

	let login: LoginService
	let permissions: () -> PermissionState
	/// The clock retention reads; tests move it forward.
	var now: () -> Date = Date.init
	static let retentionInterval: TimeInterval = 3_600

	public convenience init(directory: URL? = nil, defaults: UserDefaults = .standard) throws {
		try self.init(directory: directory, defaults: defaults, pasteboard: GeneralPasteboard(), login: MainAppLogin(),
			permissions: AppController.livePermissions, links: LiveLinkFetcher(), files: LiveFileThumbnails())
	}

	init(directory: URL?, defaults: UserDefaults, pasteboard: PasteboardSource, login: LoginService,
		permissions: @escaping () -> PermissionState, links: LinkFetching, files: FileThumbnailing,
		storageFiles: any FileOps = LiveFileOps()) throws {
		prefs = Preferences(defaults: defaults)
		let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Copia", isDirectory: true)
		store = try ClipStore(directory: dir, files: storageFiles)
		watcher = PasteboardWatcher(source: pasteboard, ignoredApps: Set(prefs.ignoredApps))
		previewer = Previewer(store: store, links: links, files: files)
		self.login = login
		self.permissions = permissions
		model = StripModel(clips: [], animator: .live(), clock: .live)
		model.paused = prefs.paused
		wire()
	}

	// MARK: Launch

	public func start(showOnboarding: Bool = true, menuAndHotkeys: Bool = true) async {
		try? await store.sweep()
		await prune()
		await reload()
		await previewer.resumePending()
		await refreshStorageStatus()
		watcher.setPaused(prefs.paused || model.storageStatus == .recoveryRequired)
		watcher.start()
		guard menuAndHotkeys else { return }
		menu = MenuBarController(actions: .init(
			history: { [weak self] in self?.toggleHistory() },
			pause: { [weak self] in self?.togglePause() },
			settings: { [weak self] in self?.openSettings() },
			quit: { NSApp.terminate(nil) }))
		menu?.setPaused(prefs.paused || model.storageStatus == .recoveryRequired)
		KeyboardShortcuts.onKeyUp(for: .copiaHistory) { [weak self] in self?.toggleHistory() }
		KeyboardShortcuts.onKeyUp(for: .copiaPause) { [weak self] in self?.togglePause() }
		let timer = Timer(timeInterval: Self.retentionInterval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { _ = Task { await self?.retentionTick() } }
		}
		timer.tolerance = 300
		RunLoop.main.add(timer, forMode: .common)
		retentionTimer = timer
		refreshPermissions()
		if showOnboarding, !prefs.onboarded || !permissions().accessibility { openOnboarding() }
	}

	private func wire() {
		panel.host.rootView = AnyView(StripView(model: model, focus: focus, thumbnails: thumbnails))
		model.announce = { [weak self] text in
			guard let panel = self?.panel else { return }
			NSAccessibility.post(element: panel, notification: .announcementRequested,
				userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
		}
		model.onOpenFinish = { [weak self] in self?.panel.invalidateShadow() }
		model.onCloseStart = { [weak self] in
			guard let self else { return }
			CopiaDebug.log("closeStart key=\(panel.isKeyWindow)")
			panel.resignKey()
			let cutoff = lastDeliveredUndoSequence
			index.clearDeletions()
			Task { await self.store.emptyTrash(through: cutoff); await self.refreshStorageStatus() }
		}
		model.onCloseFinish = { [weak self] in
			guard let self else { return }
			panel.hide()
			thumbnails.removeAll()
		}
		model.onUndoExpired = { [weak self] id in
			guard let self, let gone = index.takeDeletion(for: id) else { return }
			Task { await self.store.invalidateUndo(gone); await self.refreshStorageStatus() }
		}
		model.actions = StripActions(
			paste: { [weak self] id, plain, beginClose in
				guard let self, let key = index.keys[id] else { return .copied }
				do {
					let items = try await store.items(for: key)
					return await paster.paste(items, plain: plain, target: target, beginClose: beginClose)
				} catch {
					await refreshStorageStatus()
					throw actionError(error)
				}
			},
			copy: { [weak self] id in
				guard let self, let key = index.keys[id] else { return }
				do { paster.write(try await store.items(for: key), plain: false) }
				catch { await refreshStorageStatus(); throw actionError(error) }
			},
			delete: { [weak self] id in
				guard let self, let key = index.keys[id] else { return }
				let close = model.closeCount
				do {
					if let gone = try await store.delete(key) {
						lastDeliveredUndoSequence = max(lastDeliveredUndoSequence, gone.issuedSequence)
						index.noteDeleted(id, gone)
						if close != model.closeCount {
							_ = index.takeDeletion(for: id)
							await store.invalidateUndo(gone)
						}
					}
					await refreshStorageStatus()
				} catch {
					await refreshStorageStatus()
					throw actionError(error)
				}
			},
			restore: { _, _ in },
			openAccessibilitySettings: { Permissions.requestAccessibility(); Permissions.openAccessibilitySettings() })
		model.actions.search = { [weak self] query in
			guard let self, let keys = try? await store.search(query) else { return [] }
			return Set(keys.map(ClipDraft.uuid(forKey:)))
		}
		model.actions.restore = { [weak self] clip, _ in
			guard let self else { throw StripActionError.undoExpired }
			guard let gone = index.deletion(for: clip.id) else { throw StripActionError.undoExpired }
			do {
				let restored = try await store.restore(gone)
				index.noteRestored(clip.id, key: gone.clip.key)
				previewer.generate(for: restored)
				await refreshStorageStatus()
			} catch {
				await refreshStorageStatus()
				throw actionError(error)
			}
		}
		watcher.onDraft = { [weak self] draft in
			guard let self else { return }
			Task {
				guard self.model.storageStatus != .recoveryRequired else { return }
				guard let result = try? await self.store.insert(draft) else { await self.refreshStorageStatus(); return }
				if result.isNew { self.previewer.generate(for: result.clip) }
				await self.reload()
			}
		}
		previewer.onSaved = { [weak self] in Task { await self?.reload() } }
		panel.onKeyEquivalent = { [weak self] event in self?.keyEquivalent(event) ?? false }
		panel.onFlagsChanged = { [weak self] flags in self?.model.commandHeld = flags.contains(.command) }
		NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.model.cardsMounted, !self.model.isClosing else { return }
				self.model.beginClose()
			}
		}
		wireShell()
	}

	// MARK: Strip

	public func toggleHistory() {
		if panel.isVisible, model.cardsMounted {
			model.beginClose()
			return
		}
		let front = NSWorkspace.shared.frontmostApplication
		target = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? target : front
		let mouse = NSEvent.mouseLocation
		guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
		model.open()
		panel.show(on: screen, visibleFrame: visibleFrameOverride)
		focus.focus()
		CopiaDebug.log("opened visible=\(panel.isVisible) key=\(panel.isKeyWindow) frame=\(panel.frame)")
		DispatchQueue.main.async { [weak self] in self?.model.animateIn() }
	}

	private func keyEquivalent(_ event: NSEvent) -> Bool {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		guard flags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
		let plain = flags.contains(.shift)
		if let digit = Int(chars), (1...9).contains(digit) {
			Task { await model.paste(position: digit, plain: plain) }
			return true
		}
		switch chars {
		case "!", "@", "#", "$", "%", "^", "&", "*", "(":
			let position = Array("!@#$%^&*(").firstIndex(of: Character(chars))! + 1
			Task { await model.paste(position: position, plain: true) }
			return true
		case "c":
			if let id = model.selectedID { Task { await model.perform(.copy, id: id) } }
			return true
		case "z":
			Task { await model.undo() }
			return true
		default:
			return false
		}
	}

	/// Shows the store's current history. The newest reload wins, and one that raced a delete or restore fetches again.
	public func reload() async {
		await refreshStorageStatus()
		guard model.storageStatus != .recoveryRequired else { return }
		reloads += 1
		let mine = reloads
		while true {
			let fetchedAt = index.mutations
			guard let stored = try? await store.snapshot() else { await refreshStorageStatus(); return }
			var map: [UUID: String] = [:]
			var clips: [Clip] = []
			for row in stored {
				let id = ClipDraft.uuid(forKey: row.clip.key)
				map[id] = row.clip.key
				clips.append(Self.clip(from: row.clip, thumbnail: row.thumbnail))
			}
			guard mine == reloads else { return }
			guard index.apply(map, fetchedAt: fetchedAt) else { continue }
			model.cancelUndo(for: index.takeEndedUndos())
			model.applySnapshot(clips)
			return
		}
	}

	static func clip(from s: StoredClip, thumbnail: URL?) -> Clip {
		let preview: CopiaCore.Preview = switch s.previewState {
		case .pending: .pending
		case .ok: thumbnail.map { .ready($0) } ?? (s.kind == .image || s.kind == .file ? .failed : .pending)
		case .okNoImage: s.kind == .link ? thumbnail.map { .icon($0) } ?? .failed : .failed
		case .failed: .failed
		}
		return Clip(id: ClipDraft.uuid(forKey: s.key), kind: s.kind, text: s.title, isCode: s.isCode,
			sourceName: s.sourceName, sourceBundleID: s.sourceBundle, timestamp: s.lastCopied, meta: s.meta,
			preview: s.kind == .text || s.kind == .richText || s.kind == .color ? .pending : preview,
			fileNames: s.fileNames, colorHex: s.colorHex, url: s.url.flatMap(URL.init(string:)))
	}

	func prune() async {
		guard let cutoff = prefs.retention.cutoff(now: now()) else { return }
		_ = try? await store.prune(before: cutoff)
	}

	/// The hourly retention pass, which also retries any file a delete, prune or erase could not remove.
	func retentionTick() async {
		await prune()
		try? await store.removeOrphans()
		await reload()
	}

	/// Erases all history after the user confirmed.
	func erase() async {
		guard model.storageStatus != .recoveryRequired else { return }
		do {
			try await store.eraseAll()
			shell.eraseError = nil
		} catch StoreError.outcomeUnknown {
			await refreshStorageStatus()
			shell.eraseError = StorageStatus.recoveryRequired.message
			return
		} catch StoreError.filesLeft {
			shell.eraseError = "Some saved files could not be removed. Copia will retry cleanup."
		} catch {
			await refreshStorageStatus()
			shell.eraseError = "Couldn't erase: \(error.localizedDescription)"
			return
		}
		index.noteErased()
		model.cancelUndo(for: index.takeEndedUndos())
		await reload()
	}

	func refreshStorageStatus() async {
		let recovery = await store.recoveryRequired
		let cleanup = await store.cleanupPending
		applyStorageStatus(cleanupPending: cleanup, recoveryRequired: recovery)
	}

	func applyStorageStatus(cleanupPending: Bool, recoveryRequired: Bool) {
		// Recovery is terminal for this instance; an older asynchronous status read cannot unfreeze it.
		let recoveryRequired = recoveryRequired || model.storageStatus == .recoveryRequired
		let status: StorageStatus = recoveryRequired ? .recoveryRequired : (cleanupPending ? .cleanupPending : .ready)
		shell.storageStatus = status
		model.storageStatus = status
		if recoveryRequired {
			watcher.setPaused(true)
			model.paused = true
			shell.paused = true
			menu?.setPaused(true)
		}
	}

	private func actionError(_ error: Error) -> Error {
		if case StoreError.outcomeUnknown = error { return StripActionError.outcomeUnknown }
		if case StoreError.undoExpired = error { return StripActionError.undoExpired }
		return error
	}

	var watcherIgnoredApps: Set<String> { watcher.ignoredApps }

	func togglePause() {
		guard model.storageStatus != .recoveryRequired else { return }
		prefs.paused.toggle()
		watcher.setPaused(prefs.paused)
		model.paused = prefs.paused
		shell.paused = prefs.paused
		menu?.setPaused(prefs.paused || model.storageStatus == .recoveryRequired)
	}

	// MARK: Settings and onboarding

	private func wireShell() {
		shell.retention = prefs.retention
		shell.ignoredApps = prefs.ignoredApps
		shell.paused = prefs.paused
		shell.login = login.status
		shell.setLogin = { [weak self] on in
			guard let self else { return }
			do {
				if on { try login.register() } else { try login.unregister() }
				shell.login = login.status
			} catch {
				shell.login = .error(error.localizedDescription)
			}
		}
		shell.setRetention = { [weak self] value in
			self?.prefs.retention = value
			Task { await self?.prune(); await self?.reload() }
		}
		shell.setIgnoredApps = { [weak self] apps in
			self?.prefs.ignoredApps = apps
			self?.watcher.ignoredApps = Set(apps)
		}
		shell.erase = { [weak self] in Task { await self?.erase() } }
		shell.requestAccessibility = { Permissions.requestAccessibility() }
		shell.openAccessibility = { Permissions.openAccessibilitySettings() }
		shell.openPasteboard = { Permissions.openPasteboardSettings() }
		shell.openHistory = { [weak self] in self?.toggleHistory() }
		shell.finishOnboarding = { [weak self] in
			self?.prefs.onboarded = true
			self?.onboardingWindow?.close()
		}
		NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.refreshPermissions() }
		}
	}

	static func livePermissions() -> PermissionState {
		let pasteboard: PermissionState.Pasteboard = switch Permissions.pasteboardAccess {
		case .alwaysAllow: .allow
		case .alwaysDeny: .deny
		case .ask: .ask
		default: .unset
		}
		return PermissionState(accessibility: Permissions.accessibilityTrusted, pasteboard: pasteboard)
	}

	func refreshPermissions() {
		shell.permissions = permissions()
	}

	public func openSettings() {
		let window = settings()
		if !window.isVisible { window.center() }
		NSApp.activate()
		window.makeKeyAndOrderFront(nil)
	}

	/// The one Settings window, made on first use and kept after it closes.
	func settings() -> NSWindow {
		if let settingsWindow { return settingsWindow }
		let window = SettingsView.makeSettingsWindow(model: shell, pickApp: Self.pickApp)
		settingsWindow = window
		return window
	}

	public func openOnboarding() {
		if onboardingWindow == nil {
			let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: shell)))
			window.styleMask = [.titled, .closable, .fullSizeContentView]
			window.titlebarAppearsTransparent = true
			window.titleVisibility = .hidden
			window.isMovableByWindowBackground = true
			window.isReleasedWhenClosed = false
			window.setContentSize(OnboardingView.size)
			window.center()
			onboardingWindow = window
		}
		// Poll permissions while onboarding is open so its status updates without a relaunch.
		permissionPoll?.cancel()
		permissionPoll = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(1))
				guard let self, self.onboardingWindow?.isVisible == true else { return }
				self.refreshPermissions()
			}
		}
		NSApp.activate()
		onboardingWindow?.makeKeyAndOrderFront(nil)
	}

	static func pickApp() -> String? {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.application]
		panel.directoryURL = URL(fileURLWithPath: "/Applications")
		guard panel.runModal() == .OK, let url = panel.url else { return nil }
		return Bundle(url: url)?.bundleIdentifier
	}
}
