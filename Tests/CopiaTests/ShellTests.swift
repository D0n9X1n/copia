import Testing
import AppKit
import SwiftUI
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
