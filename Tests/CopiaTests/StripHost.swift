import AppKit
import SwiftUI
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

/// One accessibility element, read through KVC: the Swift overlay leaves the protocol's optional members ambiguous.
struct AXNode {
	let object: NSObject

	private func read(_ key: String) -> Any? {
		object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
	}

	var role: String? { read("accessibilityRole") as? String }
	var label: String { (read("accessibilityLabel") as? String) ?? "" }
	var value: String { (read("accessibilityValue") as? String) ?? "" }
	/// Screen coordinates, bottom-left origin.
	var frame: CGRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
	var actions: [NSAccessibilityCustomAction] { (read("accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? [] }
	var children: [AXNode] { ((read("accessibilityChildren") as? [Any]) ?? []).compactMap { ($0 as? NSObject).map(AXNode.init) } }
	var all: [AXNode] { [self] + children.flatMap(\.all) }
}

/// A StripView in a real window, far off every screen and fully transparent, with a recording animator.
@MainActor
final class StripHost {
	let model: StripModel
	let window: NSWindow
	var requests: [MotionEvent] = []

	/// SwiftUI builds its accessibility tree only for an assistive client; this flag makes it build one in-process.
	static func enableAccessibility() {
		_ = NSApplication.shared
		NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
	}

	init(clips: [Clip] = Fixtures.mixed, width: CGFloat = 1440, thumbnails: ThumbnailCache = ThumbnailCache(),
		overrides: CopiaOverrides = CopiaOverrides(), appear: Bool = true) {
		Self.enableAccessibility()
		model = StripModel(clips: clips)
		window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: width, height: Theme.panelHeight),
			styleMask: .borderless, backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.alphaValue = 0
		model.animator = Animator { [unowned self] event, change, completion in
			requests.append(event)
			change()
			completion()
		}
		window.contentView = NSHostingView(rootView: StripView(model: model, focus: SearchFocus(), thumbnails: thumbnails,
			now: { Fixtures.now }).environment(\.copiaOverrides, overrides))
		model.open()
		window.orderFrontRegardless()
		if appear { model.animateIn() }
	}

	func close() { window.orderOut(nil) }

	/// Lets SwiftUI run a few frames, then lays out.
	func settle(_ milliseconds: Int = 150) async {
		try? await Task.sleep(for: .milliseconds(milliseconds))
		window.contentView?.layoutSubtreeIfNeeded()
	}

	var root: AXNode { AXNode(object: window.contentView!) }
	var strip: AXNode? { root.all.first { $0.label.hasPrefix("Clipboard history") } }
	/// Cards are the only elements with custom actions.
	var cards: [AXNode] { root.all.filter { !$0.actions.isEmpty } }
	func card(containing text: String) -> AXNode? { cards.first { $0.label.contains(text) } }

	/// True when `node` lies horizontally inside the window.
	func isOnScreen(_ node: AXNode) -> Bool {
		node.frame.minX >= window.frame.minX - 0.5 && node.frame.maxX <= window.frame.maxX + 0.5
	}
}
