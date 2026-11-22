import AppKit
import SwiftUI
import Testing
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

/// Native key-window ownership is process-wide, including across independently serialized suites.
@Suite(.serialized) enum WindowTests {}

typealias AXNode = AccessibilityNode

/// A StripView in a real window, far off every screen and fully transparent, with a recording animator.
@MainActor
final class StripHost {
	let model: StripModel
	let window: NSWindow
	var requests: [MotionEvent] = []

	init(clips: [Clip] = Fixtures.mixed, width: CGFloat = 1440, thumbnails: ThumbnailCache = ThumbnailCache(),
		overrides: CopiaOverrides = CopiaOverrides(), appear: Bool = true, now: @escaping () -> Date = { Fixtures.now }) {
		AccessibilityNode.enableInProcess()
		model = StripModel(clips: clips)
		var groups: [UUID: [Clip]] = [:]
		model.actions.delete = { ids in
			let token = UUID(); groups[token] = clips.filter { ids.contains($0.id) }; return token
		}
		model.actions.restore = { groups.removeValue(forKey: $0) ?? [] }
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
			now: now, sources: .fixtures).environment(\.copiaOverrides, overrides))
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

	var root: AXNode { AXNode(window.contentView!) }
	var strip: AXNode? { root.all.first { $0.label.hasPrefix("Clipboard history") } }
	/// Cards are the only elements with custom actions. The scroll view appears twice in the tree, so dedupe by object.
	var cards: [AXNode] {
		var seen = Set<ObjectIdentifier>()
		return root.all.filter { !$0.actions.isEmpty && seen.insert(ObjectIdentifier($0.object)).inserted }
	}
	func card(containing text: String) -> AXNode? { cards.first { $0.label.contains(text) } }

	/// True when `node` lies horizontally inside the window.
	func isOnScreen(_ node: AXNode) -> Bool {
		node.frame.minX >= window.frame.minX - 0.5 && node.frame.maxX <= window.frame.maxX + 0.5
	}
}
