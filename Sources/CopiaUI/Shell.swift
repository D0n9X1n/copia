import AppKit
import Accessibility
import SwiftUI
import KeyboardShortcuts
import CopiaCore

extension KeyboardShortcuts.Name {
	public static let copiaHistory = Self("copiaHistory", initial: .init(.y, modifiers: [.command]))
	public static let copiaPause = Self("copiaPause")
}

/// The onboarding status glyph for one permission.
public enum PermissionGlyph: Equatable, Sendable {
	case granted, needed

	/// Only Always Allow lets Copia read without a prompt; default, ask and deny all still need the user.
	public init(pasteboard: PermissionState.Pasteboard) { self = pasteboard == .allow ? .granted : .needed }

	public var isGranted: Bool { self == .granted }
	public var symbol: String { isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
	public var label: String { isGranted ? "Access enabled" : "Access needed" }
	/// Light mode deepens the system green and orange so the cut-out mark keeps 3:1 against the window.
	public var tintHex: (light: UInt32, dark: UInt32) { isGranted ? (0x1A7F37, 0x30D158) : (0xB25000, 0xFF9F0A) }
}

/// Permission state shown in onboarding and Settings.
public struct PermissionState: Equatable, Sendable {
	public enum Pasteboard: Sendable { case unset, ask, allow, deny }
	public var pasteboard: Pasteboard

	public init(pasteboard: Pasteboard) { self.pasteboard = pasteboard }

	public var pasteboardGlyph: PermissionGlyph { PermissionGlyph(pasteboard: pasteboard) }
}

public enum LoginStatus: Equatable, Sendable {
	case disabled, enabled, requiresApproval, error(String)
}

public enum UpdateStatus: Equatable {
	case idle, checking, current, available(String), failed

	var message: String? {
		switch self {
		case .idle: nil
		case .checking: "Checking for updates…"
		case .current: "Copia is up to date."
		case let .available(version): "Copia \(version) is available."
		case .failed: "Couldn’t check for updates."
		}
	}

	var releaseURL: URL? {
		guard case let .available(version) = self else { return nil }
		return URL(string: "https://github.com/D0n9X1n/copia/releases/tag/v\(version)")
	}
}

/// Settings and onboarding state. The app injects the effects; the views only read and request.
@MainActor
@Observable
public final class ShellModel {
	public let version: String?
	private let comparableVersion: ReleaseVersion?
	public private(set) var updateStatus: UpdateStatus = .idle
	@ObservationIgnored public var latestVersion: () async throws -> String = { throw URLError(.resourceUnavailable) }
	public var login: LoginStatus = .disabled
	public var retention: Retention = .month
	public var ignoredApps: [String] = []
	public var paused = false
	public var showMenuBarIcon = true
	public var permissions = PermissionState(pasteboard: .unset)
	public var eraseConfirmation = false
	/// Set when an erase could not remove every file.
	public var eraseError: String?
	public var storageStatus: StorageStatus = .ready
	public var onboardingStep = 0

	@ObservationIgnored public var setLogin: (Bool) -> Void = { _ in }
	@ObservationIgnored public var setRetention: (Retention) -> Void = { _ in }
	@ObservationIgnored public var setIgnoredApps: ([String]) -> Void = { _ in }
	@ObservationIgnored public var erase: () -> Void = {}
	@ObservationIgnored public var setShowMenuBarIcon: (Bool) -> Void = { _ in }
	@ObservationIgnored public var togglePause: () -> Void = {}
	@ObservationIgnored public var openPasteboard: () -> Void = {}
	@ObservationIgnored public var openHistory: () -> Void = {}
	@ObservationIgnored public var finishOnboarding: () -> Void = {}
	@ObservationIgnored private var eraseRequested = false

	public init(version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) {
		self.version = version?.isEmpty == false ? version : nil
		comparableVersion = version.flatMap(ReleaseVersion.init)
	}

	var canCheckForUpdates: Bool { comparableVersion != nil && updateStatus != .checking }

	public func checkForUpdates() async {
		guard let current = comparableVersion, updateStatus != .checking else { return }
		updateStatus = .checking
		do {
			guard let latest = try await ReleaseVersion(latestVersion()) else { throw URLError(.cannotParseResponse) }
			updateStatus = current < latest ? .available(latest.string) : .current
		} catch {
			updateStatus = .failed
		}
	}

	public func requestErase() { eraseRequested = true; eraseConfirmation = true }
	public func cancelErase() { eraseRequested = false; eraseConfirmation = false }
	public func confirmErase() {
		guard eraseRequested else { return }
		eraseRequested = false
		eraseConfirmation = false
		erase()
	}
}

/// The status item and its menu.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
	public struct Actions {
		public var history: () -> Void
		public var pause: () -> Void
		public var settings: () -> Void
		public var quit: () -> Void
		public init(history: @escaping () -> Void, pause: @escaping () -> Void, settings: @escaping () -> Void, quit: @escaping () -> Void) {
			self.history = history; self.pause = pause; self.settings = settings; self.quit = quit
		}
	}

	public let item: NSStatusItem
	public let menu = NSMenu()
	let actions: Actions
	private var shortcutsWereEnabled = true

	/// Run before binding menu items or registering hotkeys. The package persists JSON strings, or false for disabled.
	public static func migratePauseShortcut(in defaults: UserDefaults) {
		let migrated = "migratedPauseShortcutV2", key = "KeyboardShortcuts_copiaPause"
		guard !defaults.bool(forKey: migrated) else { return }
		if let json = defaults.object(forKey: key) as? String,
			let shortcut = try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: Data(json.utf8)),
			shortcut == .init(.t, modifiers: .command) {
			defaults.removeObject(forKey: key)
		}
		defaults.set(true, forKey: migrated)
	}

	public init(actions: Actions, statusBar: NSStatusBar = .system) {
		self.actions = actions
		item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
		super.init()
		let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Copia")
		image?.isTemplate = true
		item.button?.image = image
		for menuItem in Self.items(paused: false) {
			menuItem.target = self
			menu.addItem(menuItem)
		}
		// Follow recordings, including when a shortcut is cleared.
		menu.items.first { $0.action == #selector(history) }?.setShortcut(for: .copiaHistory)
		menu.items.first { $0.action == #selector(pause) }?.setShortcut(for: .copiaPause)
		menu.delegate = self
		item.menu = menu
	}

	/// The menu rows, in order, with their titles and actions. The caller sets the target.
	static func items(paused: Bool) -> [NSMenuItem] {
		let rows = [
			NSMenuItem(title: "Open History", action: #selector(history), keyEquivalent: ""),
			NSMenuItem(title: pauseTitle(paused: paused), action: #selector(pause), keyEquivalent: ""),
			NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","),
			NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"),
		]
		return [rows[0], rows[1], .separator(), rows[2], rows[3]]
	}

	static func pauseTitle(paused: Bool) -> String { paused ? "Resume Capture" : "Pause Capture" }

	/// Dims the status icon while paused and offers Resume in place of Pause.
	static func show(paused: Bool, in menu: NSMenu, button: NSStatusBarButton?) {
		button?.appearsDisabled = paused
		menu.items.first { $0.action == #selector(pause) }?.title = pauseTitle(paused: paused)
	}

	public var button: NSStatusBarButton { item.button! }

	public func setVisible(_ visible: Bool) { item.isVisible = visible }

	public func setPaused(_ paused: Bool) { Self.show(paused: paused, in: menu, button: item.button) }

	public func menuWillOpen(_ menu: NSMenu) {
		shortcutsWereEnabled = KeyboardShortcuts.isEnabled
		KeyboardShortcuts.isEnabled = false
	}

	public func menuDidClose(_ menu: NSMenu) { KeyboardShortcuts.isEnabled = shortcutsWereEnabled }

	@objc func history() { actions.history() }
	@objc func pause() { actions.pause() }
	@objc func openSettings() { actions.settings() }
	@objc func quitApp() { actions.quit() }
}

// MARK: Settings

public enum SettingsTab: String, CaseIterable, Identifiable {
	case general = "General", shortcuts = "Shortcuts", privacy = "Privacy", about = "About"
	public var id: String { rawValue }
	public var title: String { rawValue }
	public var symbol: String {
		switch self {
		case .general: "gearshape"
		case .shortcuts: "keyboard"
		case .privacy: "hand.raised.fill"
		case .about: "info.circle"
		}
	}
}

/// One Settings pane, hosted by the native toolbar tab controller.
public struct SettingsView: View {
	public static let width: CGFloat = 560
	/// Each pane's height; the toolbar tabs sit above it.
	public static let height: CGFloat = 400
	@Bindable var model: ShellModel
	let pickApp: () -> String?
	let tab: SettingsTab
	@State private var selectedApp: String?

	public init(model: ShellModel, pickApp: @escaping () -> String? = { nil }, tab: SettingsTab = .general) {
		self.model = model
		self.pickApp = pickApp
		self.tab = tab
	}

	public var body: some View {
		Group {
			switch tab {
			case .general: general
			case .shortcuts: shortcuts
			case .privacy: privacy
			case .about: about
			}
		}
		.formStyle(.grouped)
		.frame(width: Self.width, height: Self.height)
	}

	private var general: some View {
		Form {
			Section {
				Toggle("Open at login", isOn: Binding(get: { model.login == .enabled || model.login == .requiresApproval },
					set: { model.setLogin($0) }))
				switch model.login {
				case .requiresApproval: Text("Approve Copia in System Settings → General → Login Items.").font(.callout).foregroundStyle(ShellTheme.secondary)
				case let .error(message): Text(message).font(.callout).foregroundStyle(ShellTheme.error)
				default: EmptyView()
				}
				Toggle("Show menu bar icon", isOn: Binding(get: { model.showMenuBarIcon }, set: { model.setShowMenuBarIcon($0) }))
			}
			Section("History") {
				Button(MenuBarController.pauseTitle(paused: model.paused)) { model.togglePause() }
					.disabled(model.storageStatus == .recoveryRequired)
				Picker("Keep history", selection: Binding(get: { model.retention }, set: { model.setRetention($0); model.retention = $0 })) {
					ForEach(Retention.allCases, id: \.self) { Text($0.title).tag($0) }
				}
				Button("Erase History…", role: .destructive) { model.requestErase() }
					.disabled(model.storageStatus == .recoveryRequired)
				if model.storageStatus != .ready { Text(model.storageStatus.message).font(.callout).foregroundStyle(ShellTheme.error) }
				if let message = model.eraseError { Text(message).font(.callout).foregroundStyle(ShellTheme.error) }
			}
		}
		.confirmationDialog("Erase history?", isPresented: $model.eraseConfirmation) {
			Button("Erase", role: .destructive) { model.confirmErase() }
			Button("Cancel", role: .cancel) { model.cancelErase() }
		} message: {
			Text("This permanently deletes every saved item and its previews.")
		}
	}

	private var shortcuts: some View {
		Form {
			Section {
				KeyboardShortcuts.Recorder("Show history", name: .copiaHistory)
				KeyboardShortcuts.Recorder("Pause capture", name: .copiaPause)
			} footer: {
				Text("↩ or ⌘1–9 copies and closes history. Hold ⇧ to copy plain text. Press ⌘V where you want to paste. In results: ←/→ select, ⌘A selects all, ⌘C copies without closing, ⌫ deletes, and ⌘Z undoes. ⎋ clears search or closes history.")
					.font(.callout).foregroundStyle(ShellTheme.secondary)
			}
		}
	}

	private var about: some View {
		Form {
			Section("Copia") {
				if let version = model.version { Text("Version \(version)") } else { Text("Version unavailable") }
			}
			Section("Updates") {
				Button(model.updateStatus == .failed ? "Try Again" : "Check for Updates") {
					Task { await model.checkForUpdates() }
				}.disabled(!model.canCheckForUpdates)
				if let message = model.updateStatus.message {
					HStack {
						if model.updateStatus == .checking { ProgressView().controlSize(.small).accessibilityHidden(true) }
						Text(message)
					}
				} else if !model.canCheckForUpdates {
					Text("Open a release build of Copia.app to check for updates.")
				}
				if let url = model.updateStatus.releaseURL { Link("View Release", destination: url) }
			}
		}
		.onChange(of: model.updateStatus) { _, status in
			if let message = status.message { AccessibilityNotification.Announcement(message).post() }
		}
	}

	private var privacy: some View {
		Form {
			Section {
				List(selection: $selectedApp) {
					ForEach(model.ignoredApps, id: \.self) { id in
						HStack(spacing: 8) {
							if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
								Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
								Text(FileManager.default.displayName(atPath: url.path))
							} else {
								Image(systemName: "app.dashed").frame(width: 20, height: 20)
								Text(id)
							}
						}
						.tag(id)
					}
				}
				.frame(minHeight: 120)
				HStack {
					Button { if let id = pickApp(), !model.ignoredApps.contains(id) { update(model.ignoredApps + [id]) } } label: {
						Image(systemName: "plus")
					}
					Button {
						if let selectedApp { update(model.ignoredApps.filter { $0 != selectedApp }) }
					} label: { Image(systemName: "minus") }
					.disabled(selectedApp == nil)
				}
			} header: {
				Text("Ignore copies from these apps")
			} footer: {
				Text("Copia also skips anything an app marks as concealed or transient, such as passwords.")
					.font(.callout).foregroundStyle(ShellTheme.secondary)
			}
		}
	}

	private func update(_ apps: [String]) {
		model.ignoredApps = apps
		model.setIgnoredApps(apps)
	}
}

// MARK: Onboarding

public enum OnboardingStep: Int, CaseIterable, Sendable {
	case welcome, pasteboard, tryIt
	public var title: String {
		switch self {
		case .welcome: "Welcome"
		case .pasteboard: "Pasteboard"
		case .tryIt: "Try it"
		}
	}
}

public struct OnboardingView: View {
	public static let size = CGSize(width: 640, height: 480)
	@Bindable var model: ShellModel
	let icon: NSImage?

	public init(model: ShellModel, icon: NSImage? = NSApp.applicationIconImage) {
		self.model = model
		self.icon = icon
	}

	private var step: OnboardingStep { OnboardingStep(rawValue: model.onboardingStep) ?? .welcome }

	public var body: some View {
		VStack(spacing: 0) {
			Spacer(minLength: 24)
			content.frame(maxWidth: 460)
			Spacer(minLength: 24)
			HStack(spacing: 8) {
				ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
					Circle().fill(s == step ? Color.primary : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
				}
			}
			.accessibilityElement(children: .ignore)
			.accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
			.padding(.bottom, 28)
		}
		.frame(width: Self.size.width, height: Self.size.height)
	}

	@ViewBuilder private var content: some View {
		switch step {
		case .welcome:
			page(title: "Copia remembers what you copy.",
				detail: "Open history with ⌘Y to find and copy an earlier item.",
				hero: AnyView(Image(nsImage: icon ?? NSImage()).resizable().frame(width: 128, height: 128))) {
				Button("Get Started") { next() }.shellProminentButton().controlSize(.large)
			}
		case .pasteboard:
			page(title: "Let Copia read the clipboard",
				detail: "macOS may ask before an app reads the clipboard. Choose Always Allow for Copia so it can keep your history.",
				hero: AnyView(status(model.permissions.pasteboardGlyph))) {
				if model.permissions.pasteboard == .allow {
					Button("Continue") { next() }.shellProminentButton().controlSize(.large)
				} else {
					HStack {
						Button("Continue") { next() }.buttonStyle(.glass).controlSize(.large)
						Button("Open Settings") { model.openPasteboard() }.shellProminentButton().controlSize(.large)
					}
				}
			}
		case .tryIt:
			page(title: "Try it", detail: "Copy something, then open history and press Return to copy it again. Use ⌘V in the app where you want to paste.",
				hero: AnyView(KeyboardShortcuts.Recorder("Show history", name: .copiaHistory))) {
				Button("Open History") { model.finishOnboarding(); model.openHistory() }
					.shellProminentButton().controlSize(.large)
			}
		}
	}

	private func next() { model.onboardingStep = min(model.onboardingStep + 1, OnboardingStep.allCases.count - 1) }

	private func status(_ glyph: PermissionGlyph) -> some View {
		let tint = Theme.dynamic(glyph.tintHex.light, glyph.tintHex.dark)
		return VStack(spacing: 10) {
			Image(systemName: glyph.symbol)
				.font(.system(size: 56))
				.foregroundStyle(tint)
				.contentTransition(.symbolEffect(.replace))
				.accessibilityHidden(true)
			Text(glyph.label).font(.system(size: 13, weight: .semibold))
		}
		.accessibilityElement(children: .combine)
	}

	private func page<Actions: View>(title: String, detail: String, hero: AnyView, @ViewBuilder actions: () -> Actions) -> some View {
		VStack(spacing: 18) {
			hero.frame(height: 128)
			Text(title).font(.system(size: 28, weight: .bold)).multilineTextAlignment(.center)
			Text(detail).font(.system(size: 14)).foregroundStyle(ShellTheme.secondary).multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
			actions().padding(.top, 8)
		}
	}
}
