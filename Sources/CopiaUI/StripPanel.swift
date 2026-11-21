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
		contentView = host
	}

	override public var canBecomeKey: Bool { true }
	override public var canBecomeMain: Bool { false }

	override public func performKeyEquivalent(with event: NSEvent) -> Bool {
		onKeyEquivalent(event) || super.performKeyEquivalent(with: event)
	}

	override public func flagsChanged(with event: NSEvent) {
		onFlagsChanged(event.modifierFlags)
		super.flagsChanged(with: event)
	}

	/// Places the panel on `screen` and makes it key without activating Copia.
	public func show(on screen: NSScreen, visibleFrame: CGRect? = nil) {
		setFrame(PanelLayout.windowFrame(in: visibleFrame ?? screen.visibleFrame), display: false)
		orderFrontRegardless()
		makeKey()
	}

	public func hide() {
		resignKey()
		orderOut(nil)
	}
}
