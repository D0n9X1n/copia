import Testing
import AppKit
@testable import CopiaUI

extension WindowTests {
	@MainActor @Suite struct StripPanelTests {}
}

extension WindowTests.StripPanelTests {
	@Test func rootLayerCountsEveryDisplayAndDraw() throws {
		_ = NSApplication.shared
		let panel = StripPanel()
		defer { panel.orderOut(nil) }
		let layer = try #require(panel.contentView?.layer)
		#expect(layer is CountingRootLayer)

		var before = Diagnostics.layerDisplays
		layer.setNeedsDisplay()
		layer.displayIfNeeded()
		#expect(Diagnostics.layerDisplays > before)

		let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		before = Diagnostics.layerDisplays
		layer.draw(in: context)
		#expect(Diagnostics.layerDisplays > before)
	}

	@Test func reopeningAtTheSameFrameSkipsTheAppKitFrameCall() throws {
		_ = NSApplication.shared
		let screen = try #require(NSScreen.screens.first)
		let panel = StripPanel()
		panel.alphaValue = 0
		let previousKey = NSApp.keyWindow
		defer { panel.orderOut(nil); previousKey?.makeKey() }
		// Count the actual AppKit calls; unchanged frames do not post resize notifications.
		var frameChanges = 0
		let selector = #selector(NSWindow.setFrame(_:display:))
		let method = try #require(class_getInstanceMethod(NSWindow.self, selector))
		let original = method_getImplementation(method)
		typealias SetFrame = @convention(c) (NSWindow, Selector, NSRect, Bool) -> Void
		let call = unsafeBitCast(original, to: SetFrame.self)
		let counted: @convention(block) (NSWindow, NSRect, Bool) -> Void = { window, frame, display in
			if window === panel { frameChanges += 1 }
			call(window, selector, frame, display)
		}
		let replacement = imp_implementationWithBlock(counted)
		method_setImplementation(method, replacement)
		defer {
			method_setImplementation(method, original)
			imp_removeBlock(replacement)
		}
		let visible = CGRect(x: -6000, y: -6000, width: 900, height: 900)
		panel.show(on: screen, visibleFrame: visible)
		let frame = panel.frame
		panel.hide()
		#expect(panel.frame == frame)
		frameChanges = 0
		panel.show(on: screen, visibleFrame: visible)
		#expect(frameChanges == 0)
		panel.hide()
		panel.show(on: screen, visibleFrame: visible.insetBy(dx: 50, dy: 0))
		#expect(panel.frame == PanelLayout.windowFrame(in: visible.insetBy(dx: 50, dy: 0)))
		#expect(frameChanges > 0)
	}

	@Test func hostingViewFillsThePanel() {
		_ = NSApplication.shared
		let panel = StripPanel()
		defer { panel.orderOut(nil) }
		panel.setFrame(CGRect(x: -6000, y: -6000, width: 900, height: 316), display: false)
		panel.contentView?.layoutSubtreeIfNeeded()
		#expect(panel.host.frame == panel.contentView?.bounds)
		#expect(panel.host.frame.size == CGSize(width: 900, height: 316))
	}
}
