import AppKit
import SwiftUI

extension SettingsView {
	/// The Settings window: System Settings-style toolbar tabs, each hosting one SwiftUI pane.
	/// Pass `window` to configure a window you created, such as the render harness's always-key window.
	public static func makeSettingsWindow(model: ShellModel, initialTab: SettingsTab = .general,
		pickApp: @escaping () -> String? = { nil }, window: NSWindow? = nil) -> NSWindow {
		let tabs = SettingsTabController()
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
		// The custom buttons own their titles; other display modes restore AppKit's grey labels.
		window.toolbar?.displayMode = .iconOnly
		window.toolbar?.allowsDisplayModeCustomization = false
		tabs.synchronizeSelection()
		window.isReleasedWhenClosed = false
		window.setContentSize(CGSize(width: width, height: height))
		return window
	}
}

/// Keeps AppKit's toolbar and tab management, but gives enabled tab labels explicit, readable ink.
private final class SettingsTabController: NSTabViewController {
	private var buttons: [NSToolbarItem.Identifier: NSButton] = [:]

	override func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
		willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
		let item = super.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: flag)
		guard let item,
			let index = tabViewItems.firstIndex(where: { ($0.identifier as? String) == identifier.rawValue }) else { return item }
		let button = NSButton(title: item.label, target: self, action: #selector(selectTab))
		button.image = tabViewItems[index].image
		button.tag = index
		button.setButtonType(.momentaryPushIn)
		button.bezelStyle = .toolbar
		button.isBordered = false
		button.imagePosition = .imageAbove
		button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		button.setAccessibilityLabel(item.label)
		// Toolbar AX forwards role and value, not AXSelected. Radio AXValue conveys selection.
		button.setAccessibilityRole(.radioButton)
		button.sizeToFit()
		button.frame.size = CGSize(width: max(64, button.frame.width), height: 52)
		item.view = button
		if flag { buttons[identifier] = button }
		update(button, selected: index == selectedTabViewItemIndex)
		return item
	}

	override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
		super.tabView(tabView, didSelect: tabViewItem)
		synchronizeSelection()
	}

	/// Toolbar installation resets custom button states after their creation; also sync once installed.
	func synchronizeSelection() {
		for button in buttons.values {
			update(button, selected: button.tag == selectedTabViewItemIndex)
		}
	}

	@objc private func selectTab(_ sender: NSButton) {
		selectedTabViewItemIndex = sender.tag
		// AppKit need not notify the delegate when the already-selected tab is clicked.
		update(sender, selected: true)
	}

	private func update(_ button: NSButton, selected: Bool) {
		button.state = selected ? .on : .off
		button.setAccessibilityValue(NSNumber(value: selected))
		button.contentTintColor = selected ? .controlAccentColor : NSColor(ShellTheme.secondary)
		button.attributedTitle = NSAttributedString(string: button.title, attributes: [
			.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: selected ? NSColor.labelColor : NSColor(ShellTheme.secondary),
		])
	}
}
