import Testing
import AppKit
@testable import CopiaUI

@MainActor
@Suite struct StripPanelTests {
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
