import AppKit
import SwiftUI

/// The floating, non-activating window that holds the strip. Created once and reused.
@MainActor
public final class StripPanel: NSPanel {
	public let host: NSHostingView<AnyView>
	public var onKeyEquivalent: (NSEvent) -> Bool = { _ in false }
	public var onFlagsChanged: (NSEvent.ModifierFlags) -> Void = { _ in }

	public init(rootView: AnyView = AnyView(EmptyView())) {
		host = NSHostingView(rootView: rootView)
		super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
		level = .statusBar
		collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
		isFloatingPanel = true
		becomesKeyOnlyIfNeeded = false
		hidesOnDeactivate = false
		isOpaque = false
		backgroundColor = .clear
		// The window server draws this shadow outside Copia's memory; a SwiftUI shadow would need full-width buffers.
		hasShadow = true
		animationBehavior = .none
		isReleasedWhenClosed = false
		host.sizingOptions = []
		host.autoresizingMask = [.width, .height]
		let root = CountingRootView()
		root.wantsLayer = true
		root.addSubview(host)
		contentView = root
	}

	override public var canBecomeKey: Bool { true }
	override public var canBecomeMain: Bool { false }

	/// DragGesture also recognizes a contextual down. Keep that event out of primary selection,
	/// including when the menu tracks its own nested events inside sendEvent.
	var openContextMenu: ((NSEvent) -> Bool)?
	private(set) var handlingContextClick = false
	/// The click count of the primary mouse-up being delivered, nil otherwise or after a drag.
	/// Cards read it to tell a click from a double-click.
	private(set) var primaryClickCount: Int?
	private var pressStart: CGPoint?
	private var pressMoved = false
	/// A press that began inside context-menu tracking or with Control never becomes a click.
	private var pressIsContext = false
	/// Changes on every primary press, so a card can decide once per press what it is for.
	private(set) var pressNumber = 0

	override public func sendEvent(_ event: NSEvent) {
		let previous = handlingContextClick
		handlingContextClick = previous || event.type == .rightMouseDown || event.type == .rightMouseDragged
			|| (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
		defer { handlingContextClick = previous }
		switch event.type {
		case .leftMouseDown:
			pressStart = event.locationInWindow; pressMoved = false; pressIsContext = handlingContextClick; pressNumber &+= 1
		case .leftMouseDragged, .leftMouseUp:
			if let start = pressStart, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 { pressMoved = true }
		default: break
		}
		let previousCount = primaryClickCount
		// Context-menu tracking, a Control-click and a press that moved are not clicks.
		primaryClickCount = event.type == .leftMouseUp && !handlingContextClick && !pressIsContext
			&& !event.modifierFlags.contains(.control) && !pressMoved
			? event.clickCount : nil
		defer { primaryClickCount = previousCount }
		if !previous, handlingContextClick, event.type != .rightMouseDragged, openContextMenu?(event) == true { return }
		super.sendEvent(event)
	}

	override public func performKeyEquivalent(with event: NSEvent) -> Bool {
		onKeyEquivalent(event) || super.performKeyEquivalent(with: event)
	}

	override public func flagsChanged(with event: NSEvent) {
		onFlagsChanged(event.modifierFlags)
		super.flagsChanged(with: event)
	}

	/// Places the panel on `screen` and makes it key without activating Copia.
	public func show(on screen: NSScreen, visibleFrame: CGRect? = nil) {
		let target = PanelLayout.windowFrame(in: visibleFrame ?? screen.visibleFrame)
		if frame != target { setFrame(target, display: false) }
		orderFrontRegardless()
		makeKey()
	}

	public func hide() {
		resignKey()
		orderOut(nil)
	}
}

/// The panel's root layer. Every display and draw is counted, so the benchmark can show a hidden strip draws nothing.
public final class CountingRootLayer: CALayer {
	override public func display() {
		MainActor.assumeIsolated { Diagnostics.layerDisplay() }
		super.display()
	}

	override public func draw(in ctx: CGContext) {
		MainActor.assumeIsolated { Diagnostics.layerDisplay() }
		super.draw(in: ctx)
	}
}

/// The panel's content view: holds the hosting view on a counting root layer.
final class CountingRootView: NSView {
	override func makeBackingLayer() -> CALayer { CountingRootLayer() }
}
