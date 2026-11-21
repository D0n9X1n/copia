import Testing
import AppKit
import SwiftUI
import CopiaFixtures
@testable import CopiaUI

@MainActor
@Suite struct SettingsWindowTests {
	@Test func toolbarTabsAreGeneralShortcutsPrivacyWithTheirSymbols() throws {
		_ = NSApplication.shared
		let window = SettingsView.makeSettingsWindow(model: ShellModel(), initialTab: .privacy)
		let tabs = try #require(window.contentViewController as? NSTabViewController)
		#expect(tabs.tabStyle == .toolbar)
		#expect(tabs.tabViewItems.map(\.label) == ["General", "Shortcuts", "Privacy"])
		#expect(tabs.tabViewItems.map { ($0.identifier as? String).flatMap(SettingsTab.init(rawValue:)) } == [.general, .shortcuts, .privacy])
		for (item, symbol) in zip(tabs.tabViewItems, ["gearshape", "keyboard", "hand.raised.fill"]) {
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
	@Test func titlesKeyEquivalentsAndActions() {
		let items = MenuBarController.items(paused: false)
		#expect(items.map { $0.isSeparatorItem ? "-" : $0.title } == ["Open History", "Pause Capture", "-", "Settings…", "Quit"])
		let rows = items.filter { !$0.isSeparatorItem }
		#expect(rows.map(\.keyEquivalent) == ["y", "t", ",", "q"])
		#expect(rows.allSatisfy { $0.keyEquivalentModifierMask == .command })
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
	@Test func accessibilityGrantedOrRevoked() {
		#expect(PermissionGlyph(accessibility: true) == .granted)
		#expect(PermissionGlyph(accessibility: false) == .needed)
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
			#expect(PermissionState(accessibility: false, pasteboard: state).pasteboardGlyph == glyph, "\(state)")
		}
	}

	@Test func modelChangeRedrawsTheGlyphWithoutRelaunch() {
		final class Flag: @unchecked Sendable { var fired = 0 }
		let model = ShellModel(), flag = Flag()
		func read() -> (PermissionGlyph, PermissionGlyph) {
			withObservationTracking { (model.permissions.accessibilityGlyph, model.permissions.pasteboardGlyph) }
				onChange: { flag.fired += 1 }
		}
		#expect(read() == (.needed, .needed))
		model.permissions = PermissionState(accessibility: true, pasteboard: .allow)
		#expect(flag.fired == 1)
		#expect(read() == (.granted, .granted))
		model.permissions = PermissionState(accessibility: false, pasteboard: .deny)
		#expect(flag.fired == 2)
		#expect(read() == (.needed, .needed))
	}
}
