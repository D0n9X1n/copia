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
