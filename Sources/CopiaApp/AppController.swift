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
	var showMenuBarIcon: Bool {
		get { defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true }
		nonmutating set { defaults.set(newValue, forKey: "showMenuBarIcon") }
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

/// Wires history, capture and clipboard writes into the strip, menu and Settings.
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
	let paster: Paster
	/// The pasteboard the watcher reads; its change count says whether the clipboard still holds what Copia knows.
	private let clipboardSource: PasteboardSource
	/// The stored clip Copia last wrote or captured (by key, so a reload can't lose it), with the change that put it there.
	private var onClipboard: (change: Int, key: String, plain: Bool)?
	/// The pasteboard change of Copia's own last write. A restore writes only while the pasteboard still has it.
	private var ownWrite: Int?
	/// The newest pasteboard change Copia has seen, from its own writes or the watcher.
	private var lastChange = Int.min
	/// Tests: runs after the store read, right before the pasteboard write.
	var beforePasteboardWrite: () -> Void = {}
	private let sources: SourceAppearance
	private let observesWorkspace: Bool
	private var observers: [NSObjectProtocol] = []
	let prefs: Preferences
	private var menu: MenuBarController?
	private var index = ClipIndex()
	private var reloads = 0
	private var lastDeliveredUndoSequence: UInt64 = 0
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

	public static func live() throws -> AppController {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Copia", isDirectory: true)
		let board = NSPasteboard.general
		return try AppController(directory: dir, defaults: .standard, pasteboard: GeneralPasteboard(board), writerBoard: board,
			login: MainAppLogin(), permissions: livePermissions, links: LiveLinkFetcher(), files: LiveFileThumbnails(), observesWorkspace: true)
	}

	public static func scratch(directory: URL, defaults: UserDefaults, pasteboard: NSPasteboard) throws -> AppController {
		let services = ScratchServices()
		return try AppController(directory: directory, defaults: defaults, pasteboard: GeneralPasteboard(pasteboard), writerBoard: pasteboard,
			login: services, permissions: { PermissionState(pasteboard: .allow) }, links: services, files: services)
	}

	init(directory: URL, defaults: UserDefaults, pasteboard: PasteboardSource, writerBoard: NSPasteboard, login: LoginService,
		permissions: @escaping () -> PermissionState, links: LinkFetching, files: FileThumbnailing,
		storageFiles: any FileOps = LiveFileOps(), observesWorkspace: Bool = false) throws {
		prefs = Preferences(defaults: defaults)
		self.observesWorkspace = observesWorkspace
		sources = observesWorkspace ? .shared : .fixtures
		store = try ClipStore(directory: directory, files: storageFiles)
		paster = Paster(pasteboard: writerBoard)
		clipboardSource = pasteboard
		if observesWorkspace {
			watcher = PasteboardWatcher(source: pasteboard, ignoredApps: Set(prefs.ignoredApps))
		} else {
			watcher = PasteboardWatcher(source: pasteboard, ignoredApps: Set(prefs.ignoredApps), frontmost: { nil }, appName: { _ in nil })
		}
		previewer = Previewer(store: store, links: links, files: files)
		self.login = login
		self.permissions = permissions
		model = StripModel(clips: [], animator: .live(), clock: .live)
		model.paused = prefs.paused
		wire()
	}

	isolated deinit {
		watcher.stop()
		retentionTimer?.invalidate()
		permissionPoll?.cancel()
		for observer in observers { NotificationCenter.default.removeObserver(observer) }
	}

	public var capturePollCount: Int { watcher.pollCount }

	// MARK: Launch

	public func start(showOnboarding: Bool = true, menuAndHotkeys: Bool = true) async {
		try? await store.sweep()
		await prune()
		await reload()
		await previewer.resumePending()
		await refreshStorageStatus()
		watcher.setPaused(prefs.paused || model.storageStatus == .recoveryRequired)
		watcher.start(observingWorkspace: observesWorkspace)
		guard menuAndHotkeys else { return }
		MenuBarController.migratePauseShortcut(in: prefs.defaults)
		menu = MenuBarController(actions: .init(
			history: { [weak self] in self?.toggleHistory() },
			pause: { [weak self] in self?.togglePause() },
			settings: { [weak self] in self?.openSettings() },
			quit: { NSApp.terminate(nil) }))
		menu?.setPaused(prefs.paused || model.storageStatus == .recoveryRequired)
		menu?.setVisible(prefs.showMenuBarIcon)
		KeyboardShortcuts.onKeyUp(for: .copiaHistory) { [weak self] in self?.toggleHistory() }
		KeyboardShortcuts.onKeyUp(for: .copiaPause) { [weak self] in self?.togglePause() }
		let timer = Timer(timeInterval: Self.retentionInterval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { _ = Task { await self?.retentionTick() } }
		}
		timer.tolerance = 300
		RunLoop.main.add(timer, forMode: .common)
		retentionTimer = timer
		refreshPermissions()
		if showOnboarding, !prefs.onboarded { openOnboarding() }
	}

	private func wire() {
		panel.host.rootView = AnyView(StripView(model: model, focus: focus, thumbnails: thumbnails, sources: sources))
		model.announce = { [weak self] text in
			guard let panel = self?.panel else { return }
			NSAccessibility.post(element: panel, notification: .announcementRequested,
				userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
		}
		model.onOpenFinish = { [weak self] in self?.panel.invalidateShadow() }
		model.onCloseStart = { [weak self] in
			guard let self else { return }
			panel.resignKey()
			let cutoff = lastDeliveredUndoSequence, deferCleanup = model.isClosingAfterCopy
			index.clearDeletions()
			Task {
				if let retired = await self.store.emptyTrash(through: cutoff, deferCleanup: deferCleanup) {
					_ = self.model.clock.after(StripModel.toastLifetime) { [weak self] in
						guard let self else { return }
						Task { await self.store.cleanRetiredSnapshots(retired); await self.refreshStorageStatus() }
					}
				}
				await self.refreshStorageStatus()
			}
		}
		model.onCloseFinish = { [weak self] in
			guard let self else { return }
			panel.hide()
			thumbnails.removeAll()
		}
		model.onUndoExpired = { [weak self] token in
			guard let self, index.canRestore(token) else { return }
			index.forget(token)
			Task { await self.store.invalidateGroup(token); await self.refreshStorageStatus() }
		}
		model.actions.openSettings = { [weak self] in self?.openSettings() }
		model.syncClipboard = { [weak self] in self?.watcher.tick() }
		model.actions.write = { [weak self] id, plain in
			guard let self, let key = index.keys[id] else { throw StoreError.missingBlob }
			let close = model.closeCount
			do {
				let items = try await store.items(for: key)
				// A copy made elsewhere during the read is seen (and saved) now, so it can cancel a browse, keep or restore.
				watcher.tick()
				// Checked after the read: a write whose card, presentation or browse moved on meanwhile is dropped.
				guard model.closeCount == close, model.writeIsCurrent() else { throw CancellationError() }
				// A browse, keep or restore: Paster checks right before clearing that the pasteboard is still what Copia last saw.
				let expected: Int? = model.writeRequiresOwnership ? watcher.observedChange : nil
				beforePasteboardWrite()
				let change = try paster.write(items, plain: plain, expecting: expected)
				ownWrite = change
				lastChange = max(lastChange, change)
				onClipboard = (change, key, plain)
			} catch is CancellationError {
				throw CancellationError()
			} catch { await refreshStorageStatus(); throw actionError(error) }
		}
		model.actions.delete = { [weak self] ids in
			guard let self else { throw StoreError.missingBlob }
			let keys = try ids.map { id in
				guard let key = index.keys[id] else { throw StoreError.missingBlob }
				return key
			}
			let close = model.closeCount
			do {
				let group = try await store.deleteGroup(keys)
				lastDeliveredUndoSequence = max(lastDeliveredUndoSequence, group.issuedSequence)
				index.noteDeleted(ids, token: group.token)
				if close != model.closeCount {
					index.forget(group.token)
					await store.invalidateGroup(group.token)
				}
				await refreshStorageStatus()
				return group.token
			} catch { await refreshStorageStatus(); throw actionError(error) }
		}
		model.actions.restore = { [weak self] token in
			guard let self, index.canRestore(token) else { throw StripActionError.undoExpired }
			do {
				let restored = try await store.restoreGroup(token)
				index.noteRestored(token, keys: Dictionary(uniqueKeysWithValues: restored.map { (ClipDraft.uuid(forKey: $0.key), $0.key) }))
				var clips: [Clip] = []
				for row in restored {
					clips.append(Self.clip(from: row, thumbnail: await store.thumbnail(for: row.key)))
					previewer.generate(for: row)
				}
				await refreshStorageStatus()
				return clips
			} catch {
				if case StoreError.undoExpired = error { index.forget(token) }
				await refreshStorageStatus(); throw actionError(error)
			}
		}
		model.actions.setPinned = { [weak self] id, pinned in
			guard let self, let key = index.keys[id] else { throw StoreError.missingBlob }
			do {
				try await store.setPinned(key, to: pinned)
				index.noteChanged()
				await reload()
			} catch { await refreshStorageStatus(); throw actionError(error) }
		}
		model.actions.search = { [weak self] query in
			guard let self, let keys = try? await store.search(query) else { return [] }
			return Set(keys.map(ClipDraft.uuid(forKey:)))
		}
		watcher.onChange = { [weak self] change in
			guard let self, change != ownWrite else { return }
			// Copied elsewhere, captured or not: Copia no longer knows the clipboard until a capture says otherwise,
			// and a browse, keep or restore not yet written is cancelled, even while the strip closes.
			lastChange = max(lastChange, change)
			onClipboard = nil
			model.clipboardReplaced()
		}
		watcher.onDraft = { [weak self] draft in
			guard let self else { return }
			let change = watcher.lastCaptureChange
			Task {
				guard self.model.storageStatus != .recoveryRequired else { return }
				guard let result = try? await self.store.insert(draft) else { await self.refreshStorageStatus(); return }
				if result.isNew { self.previewer.generate(for: result.clip) }
				await self.reload()
				// A newer change (Copia's own write, or another copy) since this one wins.
				guard change >= self.lastChange else { return }
				self.onClipboard = (change, result.clip.key, false)
				// Copied elsewhere while the strip is open: the lens and ⎋ follow it.
				if self.model.cardsMounted { self.model.clipboardChanged(to: self.clipboardCard()) }
			}
		}
		previewer.onSaved = { [weak self] in Task { await self?.reload() } }
		panel.onKeyEquivalent = { [weak self] event in
			guard let self else { return false }
			return focus.handleKeyEquivalent(event, model: model)
		}
		panel.onFlagsChanged = { [weak self] flags in self?.model.commandHeld = flags.contains(.command) }
		observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.model.cardsMounted, !self.model.isClosing else { return }
				self.model.beginClose()
			}
		})
		wireShell()
	}

	// MARK: Strip

	/// The stored card the clipboard holds right now, if Copia knows it.
	private func clipboardCard() -> ClipboardCard? {
		guard let onClipboard, onClipboard.change == clipboardSource.changeCount,
			let id = index.keys.first(where: { $0.value == onClipboard.key })?.key else { return nil }
		return ClipboardCard(id: id, plain: onClipboard.plain)
	}

	public func toggleHistory(on chosenScreen: NSScreen? = nil) {
		if panel.isVisible, model.cardsMounted { model.beginClose(); return }
		guard let screen = chosenScreen ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
		model.open(clipboard: clipboardCard())
		panel.show(on: screen, visibleFrame: visibleFrameOverride)
		focus.focus()
		DispatchQueue.main.async { [weak self] in self?.model.animateIn() }
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
			fileNames: s.fileNames, colorHex: s.colorHex, url: s.url.flatMap(URL.init(string:)), isPinned: s.isPinned)
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
		shell.showMenuBarIcon = prefs.showMenuBarIcon
		shell.setShowMenuBarIcon = { [weak self] visible in
			guard let self else { return }
			prefs.showMenuBarIcon = visible
			shell.showMenuBarIcon = visible
			menu?.setVisible(visible)
		}
		shell.togglePause = { [weak self] in self?.togglePause() }
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
		if observesWorkspace {
			shell.openPasteboard = { Permissions.openPasteboardSettings() }
			shell.latestVersion = { try await ReleaseLookup.latest() }
		}
		shell.openHistory = { [weak self] in self?.toggleHistory() }
		shell.finishOnboarding = { [weak self] in
			self?.prefs.onboarded = true
			self?.onboardingWindow?.close()
		}
		observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.refreshPermissions() }
		})
	}

	static func livePermissions() -> PermissionState {
		let pasteboard: PermissionState.Pasteboard = switch Permissions.pasteboardAccess {
		case .alwaysAllow: .allow
		case .alwaysDeny: .deny
		case .ask: .ask
		default: .unset
		}
		return PermissionState(pasteboard: pasteboard)
	}

	func refreshPermissions() {
		shell.permissions = permissions()
	}

	public func openSettings() {
		let window = settings()
		if !window.isVisible { window.center() }
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		window.makeMain()
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
