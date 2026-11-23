import Testing
import AppKit
import SwiftUI
import KeyboardShortcuts
import CopiaFixtures
@testable import CopiaUI

extension WindowTests {
	@MainActor @Suite struct SettingsWindowTests {}
}

extension WindowTests.SettingsWindowTests {
	@Test func generalControlsHideTheIconAndStillPauseAndResume() async throws {
		AccessibilityNode.enableInProcess()
		let model = ShellModel()
		#expect(model.showMenuBarIcon)
		var visibilityRequests: [Bool] = []
		model.setShowMenuBarIcon = { [weak model] in visibilityRequests.append($0); model?.showMenuBarIcon = $0 }
		model.togglePause = { [weak model] in model?.paused.toggle() }
		// Host only General: this test never creates recorders or binds live shortcuts.
		let view = NSHostingView(rootView: SettingsView(model: model))
		let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: SettingsView.width, height: SettingsView.height),
			styleMask: .borderless, backing: .buffered, defer: false)
		window.contentView = view
		window.alphaValue = 0
		window.orderFrontRegardless()
		defer { window.orderOut(nil) }
		func press(_ label: String) async throws {
			try await Task.sleep(for: .milliseconds(150))
			view.layoutSubtreeIfNeeded()
			let nodes = AccessibilityNode(view).all
			let control = try #require(nodes.first { node in
				guard ["AXCheckBox", "AXSwitch", "AXButton"].contains(node.role ?? "") else { return false }
				if node.label == label { return true }
				let key = "accessibilityTitleUIElement"
				guard node.object.responds(to: NSSelectorFromString(key)), let title = node.object.value(forKey: key) as? NSObject else { return false }
				return AccessibilityNode(title).value == label
			})
			let press = NSSelectorFromString("accessibilityPerformPress")
			try #require(control.object.responds(to: press))
			typealias Press = @convention(c) (AnyObject, Selector) -> Bool
			_ = unsafeBitCast(control.object.method(for: press), to: Press.self)(control.object, press)
		}
		try await press("Show menu bar icon")
		#expect(visibilityRequests == [false])
		#expect(!model.showMenuBarIcon)
		try await press("Pause Capture")
		#expect(model.paused)
		try await press("Resume Capture")
		#expect(!model.paused)
	}

	@Test func aboutShowsRunningVersionAndChecksOnlyFromItsButton() async throws {
		AccessibilityNode.enableInProcess()
		let model = ShellModel(version: "0.0.2"); var calls = 0
		var pending: CheckedContinuation<String, any Error>?
		model.latestVersion = {
			calls += 1
			if calls == 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
			return "0.0.10"
		}
		let window = SettingsView.makeSettingsWindow(model: model, initialTab: .about)
		window.setFrameOrigin(CGPoint(x: -6000, y: -6000)); window.alphaValue = 0; window.orderFrontRegardless()
		defer { pending?.resume(throwing: CancellationError()); window.orderOut(nil) }
		let view = try #require(window.contentView)
		func node(_ text: String) -> AccessibilityNode? {
			view.layoutSubtreeIfNeeded()
			return AccessibilityNode(view).all.first { $0.label == text || $0.value == text }
		}
		func press(_ label: String) throws {
			let button = try #require(node(label)?.object), selector = NSSelectorFromString("accessibilityPerformPress")
			try #require(button.responds(to: selector))
			typealias Press = @convention(c) (AnyObject, Selector) -> Bool
			_ = unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector)
		}
		try #require(await eventually { node("Version 0.0.2") != nil })
		#expect(calls == 0 && node("View Release") == nil)
		try press("Check for Updates")
		try #require(await eventually { pending != nil && node("Checking for updates…") != nil })
		let busy = try #require(node("Check for Updates")?.object)
		#expect((busy.value(forKey: "isAccessibilityEnabled") as? Bool) == false)
		pending?.resume(throwing: URLError(.notConnectedToInternet)); pending = nil
		try #require(await eventually { node("Couldn’t check for updates.") != nil && node("Try Again") != nil })
		#expect(node("View Release") == nil)
		try press("Try Again")
		try #require(await eventually { node("Copia 0.0.10 is available.") != nil && node("View Release") != nil })
		#expect(calls == 2 && model.updateStatus.releaseURL?.absoluteString == "https://github.com/D0n9X1n/copia/releases/tag/v0.0.10")
	}

	@Test func toolbarTabsIncludeAboutAfterPrivacy() throws {
		_ = NSApplication.shared
		let window = SettingsView.makeSettingsWindow(model: ShellModel(), initialTab: .privacy)
		let tabs = try #require(window.contentViewController as? NSTabViewController)
		#expect(tabs.tabStyle == .toolbar)
		#expect(tabs.tabViewItems.map(\.label) == ["General", "Shortcuts", "Privacy", "About"])
		#expect(tabs.tabViewItems.map { ($0.identifier as? String).flatMap(SettingsTab.init(rawValue:)) } == [.general, .shortcuts, .privacy, .about])
		for (item, symbol) in zip(tabs.tabViewItems, ["gearshape", "keyboard", "hand.raised.fill", "info.circle"]) {
			let expected = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.tiffRepresentation
			#expect(item.image?.tiffRepresentation == expected, "\(item.label) should use \(symbol)")
		}
		#expect(tabs.selectedTabViewItemIndex == 2)
	}

	@Test func toolbarButtonsKeepReadableTitlesAndNativeSelectionActions() throws {
		_ = NSApplication.shared
		let window = SettingsView.makeSettingsWindow(model: ShellModel(), initialTab: .privacy)
		defer { window.orderOut(nil) }
		let tabs = try #require(window.contentViewController as? NSTabViewController)
		let toolbar = try #require(window.toolbar)
		let items = toolbar.items.filter { SettingsTab(rawValue: $0.itemIdentifier.rawValue) != nil }
		#expect(items.map(\.label) == SettingsTab.allCases.map(\.title))
		let buttons = try items.map { try #require($0.view as? NSButton, "Tab titles need explicit, accessible ink") }
		#expect(toolbar.displayMode == .iconOnly, "The button owns its label; no second system-grey toolbar label")
		let nativeDelegate = try #require(toolbar.delegate)
		#expect(tabs.tabView.delegate === tabs)

		func checkSelection(_ index: Int) {
			#expect(tabs.selectedTabViewItemIndex == index)
			#expect(toolbar.selectedItemIdentifier == items[index].itemIdentifier)
			for (i, button) in buttons.enumerated() {
				#expect(button.state == (i == index ? .on : .off))
				#expect(button.accessibilityRole() == .radioButton)
				#expect((button.accessibilityValue() as? NSNumber)?.intValue == (i == index ? 1 : 0))
			}
		}
		checkSelection(2)
		for (i, button) in buttons.enumerated() {
			#expect(button.isEnabled && button.isAccessibilityEnabled())
			#expect(button.accessibilityLabel() == items[i].label)
			#expect(button.imagePosition == .imageAbove)
			#expect(button.image?.tiffRepresentation == tabs.tabViewItems[i].image?.tiffRepresentation)
			#expect(button.attributedTitle.string == items[i].label)
			button.performClick(nil)
			checkSelection(i)
			button.performClick(nil)
			checkSelection(i) // Clicking the selected tab must not turn it off.
		}
		_ = buttons[0].accessibilityPerformPress()
		checkSelection(0)
		tabs.selectedTabViewItemIndex = 1
		checkSelection(1)
		tabs.tabView.selectNextTabViewItem(nil)
		checkSelection(2)
		tabs.tabView.selectPreviousTabViewItem(nil)
		checkSelection(1)

		for dark in [false, true] {
			window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
			for button in buttons {
				let color = try #require(button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
				let ink = ShellThemeTests.resolved(color, dark: dark)
				for surface in ShellThemeTests.surfaces(dark: dark) {
					#expect(Theme.contrast(ink, surface) >= 4.5, "\(button.title) \(dark ? "dark" : "light")")
				}
			}
		}
		#expect(toolbar.delegate === nativeDelegate, "Keep AppKit in charge of the toolbar")
		#expect(window.frame.width == 560)
	}

	@Test func toolbarPreventsDisplayModeCustomizationFromRestoringGreyLabels() throws {
		_ = NSApplication.shared
		let window = SettingsView.makeSettingsWindow(model: ShellModel())
		let toolbar = try #require(window.toolbar)
		#expect(toolbar.displayMode == .iconOnly)
		#expect(!toolbar.allowsDisplayModeCustomization)
	}

	@Test func windowToolbarExposesTabButtonsWithSelectionAndPressActions() throws {
		AccessibilityNode.enableInProcess()
		let window = SettingsView.makeSettingsWindow(model: ShellModel(), initialTab: .privacy)
		defer { window.orderOut(nil) }
		// The real window exposes its installed toolbar without ordering an unrelated test window front.
		window.contentView?.layoutSubtreeIfNeeded()
		let tabs = try #require(window.contentViewController as? NSTabViewController)
		let toolbar = try #require(AccessibilityNode(window).all.first { $0.role == NSAccessibility.Role.toolbar.rawValue })
		func exposedTabs() -> [AccessibilityNode] {
			toolbar.all.filter { SettingsTab(rawValue: $0.label) != nil }
		}
		func checkSelection(_ index: Int) throws {
			let nodes = exposedTabs()
			#expect(nodes.map(\.label) == SettingsTab.allCases.map(\.title))
			#expect(tabs.selectedTabViewItemIndex == index)
			for (i, node) in nodes.enumerated() {
				#expect(node.role == NSAccessibility.Role.radioButton.rawValue, "\(node.label) is a mutually exclusive tab, not a checkbox")
				// NSAccessibilityRadioButton defines selection through AXValue, not AXSelected.
				let element = try #require(node.object as? any NSAccessibilityProtocol)
				#expect((element.accessibilityValue() as? NSNumber)?.intValue == (i == index ? 1 : 0))
			}
		}
		try checkSelection(2)
		let general = try #require(exposedTabs().first { $0.label == "General" }?.object as? any NSAccessibilityProtocol)
		// Stock AppKit toolbar items return false even after sending AXPress; test the resulting selection.
		_ = general.accessibilityPerformPress()
		try checkSelection(0)
		_ = general.accessibilityPerformPress()
		try checkSelection(0)
		tabs.selectedTabViewItemIndex = 1
		try checkSelection(1)
		tabs.tabView.selectNextTabViewItem(nil)
		try checkSelection(2)
	}

	@Test func loginAndEraseErrorsRenderAtAAContrastInBothAppearances() async throws {
		AccessibilityNode.enableInProcess()
		for dark in [false, true] {
			let model = ShellModel()
			model.login = .error("Could not enable login.")
			model.eraseError = "Could not erase history."
			let window = SettingsView.makeSettingsWindow(model: model)
			defer { window.orderOut(nil) }
			window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
			window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
			window.alphaValue = 0
			window.orderFrontRegardless()
			try await Task.sleep(for: .milliseconds(150))
			let view = try #require(window.contentView)
			view.layoutSubtreeIfNeeded()
			let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
			view.cacheDisplay(in: view.bounds, to: rep)
			let image = try #require(rep.cgImage)
			let bitmap = ContrastCheck.Bitmap(image)
			let screen = view.convert(view.bounds, to: nil)
			let origin = window.convertToScreen(screen)
			for message in ["Could not enable login.", "Could not erase history."] {
				let node = try #require(AccessibilityNode(view).all.first { $0.value == message || $0.label == message })
				let box = CGRect(x: node.frame.minX - origin.minX, y: origin.maxY - node.frame.maxY,
					width: node.frame.width, height: node.frame.height)
				let ratio = ContrastCheck.text(in: bitmap, box: box, scale: CGFloat(image.width) / view.bounds.width)
				#expect(ratio >= 4.5, "\(dark ? "dark" : "light") \(message): \(ratio):1")
			}
		}
	}

	@Test func settingsExposesPersistentStorageWarningAndDisablesEraseDuringRecovery() async throws {
		AccessibilityNode.enableInProcess()
		for status in [StorageStatus.cleanupPending, .recoveryRequired] {
			let model = ShellModel()
			model.storageStatus = status
			let window = SettingsView.makeSettingsWindow(model: model)
			window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
			window.alphaValue = 0
			window.orderFrontRegardless()
			defer { window.orderOut(nil) }
			try await Task.sleep(for: .milliseconds(150))
			window.contentView?.layoutSubtreeIfNeeded()
			let nodes = AccessibilityNode(window).all
			#expect(nodes.contains { $0.value == status.message || $0.label == status.message })
			let erase = try #require(nodes.first { $0.label == "Erase History…" }?.object)
			#expect(erase.responds(to: NSSelectorFromString("isAccessibilityEnabled")))
			#expect((erase.value(forKey: "isAccessibilityEnabled") as? Bool) == (status != .recoveryRequired))
		}
	}

	@Test func windowIs560PointsWide() {
		_ = NSApplication.shared
		for tab in SettingsTab.allCases {
			let window = SettingsView.makeSettingsWindow(model: ShellModel(), initialTab: tab)
			#expect(window.frame.width == 560)
			#expect(window.contentLayoutRect.width == 560)
		}
	}
}

/// Shell copy and button colors against the surfaces Settings and onboarding draw on.
@MainActor
@Suite struct ShellThemeTests {
	/// sRGB of `color` under the light or dark appearance, composited over `base` when translucent.
	static func resolved(_ color: NSColor, dark: Bool, over base: SIMD3<Double>? = nil) -> SIMD3<Double> {
		var out = SIMD3<Double>(repeating: 0)
		NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
			let c = color.usingColorSpace(.sRGB)!
			let rgb: SIMD3<Double> = SIMD3(c.redComponent, c.greenComponent, c.blueComponent)
			out = base.map { Theme.composite(rgb, over: $0, alpha: c.alphaComponent) } ?? rgb
		}
		return out
	}

	/// The window, page and control backgrounds, and grouped-row fills over the window.
	static func surfaces(dark: Bool) -> [SIMD3<Double>] {
		let window = resolved(.windowBackgroundColor, dark: dark)
		return [window, resolved(.underPageBackgroundColor, dark: dark), resolved(.controlBackgroundColor, dark: dark)]
			+ [NSColor.quaternarySystemFill, .tertiarySystemFill, .secondarySystemFill].map { resolved($0, dark: dark, over: window) }
	}

	@Test func secondaryCopyReachesAAOnEverySurface() {
		for dark in [false, true] {
			let ink = Theme.rgb(dark ? ShellTheme.Hex.secondaryDark : ShellTheme.Hex.secondaryLight)
			for surface in Self.surfaces(dark: dark) {
				#expect(Theme.contrast(ink, surface) >= 4.5, "\(dark ? "dark" : "light") secondary on \(surface)")
			}
		}
	}

	/// One fixed fill for both modes: the system accent is the user's choice, so it can't promise 4.5:1.
	@Test func accentButtonLabelReachesAAWithGlassSheen() {
		let label = Theme.rgb(ShellTheme.Hex.onAccent)
		let fill = Theme.rgb(ShellTheme.Hex.accent)
		#expect(Theme.contrast(label, fill) >= 4.5)
		// Liquid Glass washes the fill lighter: renders lost about 0.2 (3.18 → 2.99), roughly a 7% white wash. Allow 10%.
		let sheen = Theme.composite(SIMD3(repeating: 1), over: fill, alpha: 0.10)
		#expect(Theme.contrast(label, sheen) >= 4.5)
	}
}

/// Erase History asks first; only Erase in the confirmation runs the erase.
@MainActor
@Suite struct EraseConfirmationTests {
	final class Spy { var erases = 0 }

	static func model(_ spy: Spy) -> ShellModel {
		let model = ShellModel()
		model.erase = { spy.erases += 1 }
		return model
	}

	@Test func requestOnlyAsks() {
		let spy = Spy(), model = Self.model(spy)
		model.requestErase()
		#expect(model.eraseConfirmation)
		#expect(spy.erases == 0)
	}

	@Test func confirmErasesOnce() {
		let spy = Spy(), model = Self.model(spy)
		model.requestErase()
		model.confirmErase()
		model.confirmErase()
		#expect(spy.erases == 1)
		#expect(!model.eraseConfirmation)
	}

	@Test func cancelLeavesDataUntouched() {
		let spy = Spy(), model = Self.model(spy)
		model.requestErase()
		model.cancelErase()
		model.confirmErase()
		#expect(spy.erases == 0)
		#expect(!model.eraseConfirmation)
	}

	@Test func confirmWithoutRequestDoesNothing() {
		let spy = Spy(), model = Self.model(spy)
		model.confirmErase()
		#expect(spy.erases == 0)
	}
}

/// The status menu, checked without a live status bar.
@MainActor
@Suite struct MenuTests {
	@Test func pauseHasNoInitialGlobalShortcut() {
		#expect(KeyboardShortcuts.Name.copiaPause.initialShortcut == nil)
	}

	@Test func migrationOnlyClearsTheOldDefaultOnce() throws {
		func encode(_ shortcut: KeyboardShortcuts.Shortcut) throws -> String {
			String(decoding: try JSONEncoder().encode(shortcut), as: UTF8.self)
		}
		let old = try encode(.init(.t, modifiers: .command))
		let custom = try encode(.init(.t, modifiers: [.shift, .command]))
		for initial: Any? in [old, custom, false, nil] {
			let suite = "copia.shortcuts.\(UUID().uuidString)"
			let defaults = try #require(UserDefaults(suiteName: suite))
			defer { defaults.removePersistentDomain(forName: suite) }
			let key = "KeyboardShortcuts_copiaPause"
			defaults.set(initial, forKey: key)
			defaults.set("unrelated", forKey: "sentinel")
			MenuBarController.migratePauseShortcut(in: defaults)
			if initial as? String == custom {
				#expect(defaults.object(forKey: key) as? String == custom)
			} else if initial is Bool {
				#expect(defaults.object(forKey: key) as? Bool == false)
			} else {
				#expect(defaults.object(forKey: key) == nil)
			}
			#expect(defaults.string(forKey: "sentinel") == "unrelated")
			// An intentional recording of ⌘T after migration survives a relaunch, even on a fresh install.
			defaults.set(old, forKey: key)
			MenuBarController.migratePauseShortcut(in: defaults)
			#expect(defaults.string(forKey: key) == old)
		}
	}

	@Test func titlesKeyEquivalentsAndActions() {
		let items = MenuBarController.items(paused: false)
		#expect(items.map { $0.isSeparatorItem ? "-" : $0.title } == ["Open History", "Pause Capture", "-", "Settings…", "Quit"])
		let rows = items.filter { !$0.isSeparatorItem }
		#expect(rows.map(\.keyEquivalent) == ["", "", ",", "q"])
		#expect(rows.suffix(2).allSatisfy { $0.keyEquivalentModifierMask == .command })
		#expect(rows.map(\.action) == [#selector(MenuBarController.history), #selector(MenuBarController.pause),
			#selector(MenuBarController.openSettings), #selector(MenuBarController.quitApp)])
	}

	@Test func pausedMenuOffersResume() {
		#expect(MenuBarController.items(paused: true)[1].title == "Resume Capture")
	}

	@Test func setPausedDimsTheIconAndTogglesTheTitle() {
		let menu = NSMenu()
		MenuBarController.items(paused: false).forEach(menu.addItem)
		let button = NSStatusBarButton(frame: .zero)
		MenuBarController.show(paused: true, in: menu, button: button)
		#expect(button.appearsDisabled)
		#expect(menu.items[1].title == "Resume Capture")
		MenuBarController.show(paused: false, in: menu, button: button)
		#expect(!button.appearsDisabled)
		#expect(menu.items[1].title == "Pause Capture")
	}
}

/// The onboarding status glyph follows each injected permission state.
@MainActor
@Suite struct PermissionGlyphTests {
	@Test func onboardingAsksOnlyForClipboardAccess() {
		#expect(OnboardingStep.allCases.map(\.title) == ["Welcome", "Pasteboard", "Try it"])
	}

	@Test func glyphsDistinguishGrantedFromNeeded() {
		#expect(PermissionGlyph.granted.symbol == "checkmark.circle.fill")
		#expect(PermissionGlyph.needed.symbol == "exclamationmark.triangle.fill")
		#expect(PermissionGlyph.granted.isGranted && !PermissionGlyph.needed.isGranted)
	}

	/// The check and the exclamation mark are cut out of the fill, so the fill must stand 3:1 off the window it sits on.
	@Test func statusFillsReachNonTextContrastInBothModes() {
		for dark in [false, true] {
			let window = ShellThemeTests.resolved(.windowBackgroundColor, dark: dark)
			for glyph in [PermissionGlyph.granted, .needed] {
				let fill = Theme.rgb(dark ? glyph.tintHex.dark : glyph.tintHex.light)
				#expect(Theme.contrast(fill, window) >= 3, "\(glyph) \(dark ? "dark" : "light")")
			}
		}
	}

	/// The state is said in words too, not only by colour and shape.
	@Test func statusIsSpelledOut() {
		#expect(PermissionGlyph.granted.label == "Access enabled")
		#expect(PermissionGlyph.needed.label == "Access needed")
	}

	@Test func pasteboardEveryState() {
		let expected: [(PermissionState.Pasteboard, PermissionGlyph)] = [(.unset, .needed), (.ask, .needed), (.allow, .granted), (.deny, .needed)]
		for (state, glyph) in expected {
			#expect(PermissionGlyph(pasteboard: state) == glyph, "\(state)")
			#expect(PermissionState(pasteboard: state).pasteboardGlyph == glyph, "\(state)")
		}
	}

	@Test func modelChangeRedrawsTheGlyphWithoutRelaunch() {
		final class Flag: @unchecked Sendable { var fired = 0 }
		let model = ShellModel(), flag = Flag()
		func read() -> PermissionGlyph {
			withObservationTracking { model.permissions.pasteboardGlyph }
				onChange: { flag.fired += 1 }
		}
		#expect(read() == .needed)
		model.permissions = PermissionState(pasteboard: .allow)
		#expect(flag.fired == 1)
		#expect(read() == .granted)
		model.permissions = PermissionState(pasteboard: .deny)
		#expect(flag.fired == 2)
		#expect(read() == .needed)
	}
}
