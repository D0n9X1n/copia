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
	private var target: NSRunningApplication?
	private var retentionTimer: Timer?
	private var settingsWindow: NSWindow?
	private var onboardingWindow: NSWindow?
	private var permissionPoll: Task<Void, Never>?
	/// Places the strip in this frame instead of the screen's visible frame (used by the benchmark).
	public var visibleFrameOverride: CGRect?

	public init(directory: URL? = nil, defaults: UserDefaults = .standard) throws {
		prefs = Preferences(defaults: defaults)
		let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Copia", isDirectory: true)
		store = try ClipStore(directory: dir)
		watcher = PasteboardWatcher(ignoredApps: Set(prefs.ignoredApps))
		previewer = Previewer(store: store)
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
		watcher.setPaused(prefs.paused)
		watcher.start()
		guard menuAndHotkeys else { return }
		menu = MenuBarController(actions: .init(
			history: { [weak self] in self?.toggleHistory() },
			pause: { [weak self] in self?.togglePause() },
			settings: { [weak self] in self?.openSettings() },
			quit: { NSApp.terminate(nil) }))
		menu?.setPaused(prefs.paused)
		KeyboardShortcuts.onKeyUp(for: .copiaHistory) { [weak self] in self?.toggleHistory() }
		KeyboardShortcuts.onKeyUp(for: .copiaPause) { [weak self] in self?.togglePause() }
		let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { Task { await self?.prune(); await self?.reload() } }
		}
		timer.tolerance = 300
		RunLoop.main.add(timer, forMode: .common)
		retentionTimer = timer
		refreshPermissions()
		if showOnboarding, !prefs.onboarded || !Permissions.accessibilityTrusted { openOnboarding() }
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
			CopiaDebug.log("closeStart key=\(self?.panel.isKeyWindow ?? false)")
			self?.panel.resignKey()
		}
		model.onCloseFinish = { [weak self] in
			guard let self else { return }
			panel.hide()
			thumbnails.removeAll()
			index.clearDeletions()
			Task { await self.store.emptyTrash() }
		}
		model.actions = StripActions(
			paste: { [weak self] id, plain, beginClose in
				guard let self, let key = index.keys[id] else { return .copied }
				let items = try await store.items(for: key)
				return await paster.paste(items, plain: plain, target: target, beginClose: beginClose)
			},
			copy: { [weak self] id in
				guard let self, let key = index.keys[id] else { return }
				paster.write(try await store.items(for: key), plain: false)
			},
			delete: { [weak self] id in
				guard let self, let key = index.keys[id] else { return }
				if let gone = try await store.delete(key) { index.noteDeleted(id, gone) }
			},
			restore: { [weak self] _, _ in },
			openAccessibilitySettings: { Permissions.requestAccessibility(); Permissions.openAccessibilitySettings() })
		model.actions.restore = { [weak self] clip, _ in
			guard let self, let gone = index.deletion(for: clip.id) else { return }
			try await store.restore(gone)
			index.noteRestored(clip.id, key: gone.clip.key)
			if let restored = try await store.fetch(gone.clip.key) { previewer.generate(for: restored) }
		}
		watcher.onDraft = { [weak self] draft in
			guard let self else { return }
			Task {
				guard let result = try? await self.store.insert(draft) else { return }
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
		reloads += 1
		let mine = reloads
		while true {
			let fetchedAt = index.mutations
			guard let stored = try? await store.recent() else { return }
			var map: [UUID: String] = [:]
			var clips: [Clip] = []
			for s in stored {
				let id = ClipDraft.uuid(forKey: s.key)
				map[id] = s.key
				clips.append(Self.clip(from: s, thumbnail: await store.thumbnail(for: s.key)))
			}
			guard mine == reloads else { return }
			guard index.apply(map, fetchedAt: fetchedAt) else { continue }
			model.applySnapshot(clips)
			return
		}
	}

	static func clip(from s: StoredClip, thumbnail: URL?) -> Clip {
		let preview: CopiaCore.Preview = switch s.previewState {
		case .pending: .pending
		case .ok: thumbnail.map { .ready($0) } ?? (s.kind == .image || s.kind == .file ? .failed : .pending)
		case .okNoImage, .failed: .failed
		}
		return Clip(id: ClipDraft.uuid(forKey: s.key), kind: s.kind, text: s.title, isCode: s.isCode,
			sourceName: s.sourceName, sourceBundleID: s.sourceBundle, timestamp: s.lastCopied, meta: s.meta,
			preview: s.kind == .text || s.kind == .richText || s.kind == .color ? .pending : preview,
			fileNames: s.fileNames, colorHex: s.colorHex, url: s.url.flatMap(URL.init(string:)))
	}

	func prune() async {
		guard let cutoff = prefs.retention.cutoff(now: .now) else { return }
		_ = try? await store.prune(before: cutoff)
	}

	func togglePause() {
		prefs.paused.toggle()
		watcher.setPaused(prefs.paused)
		model.paused = prefs.paused
		shell.paused = prefs.paused
		menu?.setPaused(prefs.paused)
	}

	// MARK: Settings and onboarding

	private func wireShell() {
		shell.retention = prefs.retention
		shell.ignoredApps = prefs.ignoredApps
		shell.paused = prefs.paused
		shell.login = Self.loginStatus()
		shell.setLogin = { [weak self] on in
			do {
				if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
				self?.shell.login = Self.loginStatus()
			} catch {
				self?.shell.login = .error(error.localizedDescription)
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
		shell.erase = { [weak self] in
			guard let self else { return }
			Task {
				try? await self.store.eraseAll()
				self.index.noteErased()
				await self.reload()
			}
		}
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

	static func loginStatus() -> LoginStatus {
		switch SMAppService.mainApp.status {
		case .enabled: .enabled
		case .requiresApproval: .requiresApproval
		default: .disabled
		}
	}

	func refreshPermissions() {
		let pasteboard: PermissionState.Pasteboard = switch Permissions.pasteboardAccess {
		case .alwaysAllow: .allow
		case .alwaysDeny: .deny
		case .ask: .ask
		default: .unset
		}
		shell.permissions = PermissionState(accessibility: Permissions.accessibilityTrusted, pasteboard: pasteboard)
	}

	public func openSettings() {
		if settingsWindow == nil {
			let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: shell, pickApp: Self.pickApp)))
			window.title = "Copia Settings"
			window.styleMask = [.titled, .closable]
			window.isReleasedWhenClosed = false
			window.center()
			settingsWindow = window
		}
		NSApp.activate()
		settingsWindow?.makeKeyAndOrderFront(nil)
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
