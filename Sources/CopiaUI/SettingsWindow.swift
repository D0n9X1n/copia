import AppKit
import SwiftUI

extension SettingsView {
	/// The Settings window: System Settings-style toolbar tabs, each hosting one SwiftUI pane.
	/// Pass `window` to configure a window you created, such as the render harness's always-key window.
	public static func makeSettingsWindow(model: ShellModel, initialTab: SettingsTab = .general,
		pickApp: @escaping () -> String? = { nil }, window: NSWindow? = nil) -> NSWindow {
		let tabs = NSTabViewController()
		tabs.tabStyle = .toolbar
		for tab in SettingsTab.allCases {
			let pane = NSHostingController(rootView: SettingsView(model: model, pickApp: pickApp, tab: tab))
			pane.title = tab.title
			let item = NSTabViewItem(viewController: pane)
			// The toolbar uses the identifier as its item identifier, so it must be a string.
			item.identifier = tab.rawValue
			item.label = tab.title
			item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
			tabs.addTabViewItem(item)
		}
		tabs.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: initialTab) ?? 0
		let window = window ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
		window.styleMask = [.titled, .closable]
		window.toolbarStyle = .preference
		window.contentViewController = tabs
		window.isReleasedWhenClosed = false
		window.setContentSize(CGSize(width: width, height: height))
		return window
	}
}
