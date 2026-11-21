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
