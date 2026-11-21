import AppKit

/// Where the strip sits on a screen, and how far the row scrolls to keep the selection in view.
public enum PanelLayout {
	/// Room around the strip for its shadow and the open animation; the window is this much larger.
	public static let margin = NSEdgeInsets(top: 40, left: 24, bottom: 0, right: 24)

	/// The strip's own frame: inset 8 pt inside the visible frame (above the Dock), 316 pt tall.
	public static func stripFrame(in visible: CGRect) -> CGRect {
		CGRect(x: visible.minX + Theme.panelInset, y: visible.minY + Theme.panelInset,
			width: visible.width - 2 * Theme.panelInset, height: Theme.panelHeight)
	}

	/// The panel window's frame: the strip frame plus the margins.
	public static func windowFrame(in visible: CGRect) -> CGRect {
		let strip = stripFrame(in: visible)
		return CGRect(x: strip.minX - margin.left, y: strip.minY - margin.bottom,
			width: strip.width + margin.left + margin.right, height: strip.height + margin.top + margin.bottom)
	}

	/// The card's leading x in the row's content coordinates.
	public static func cardMinX(index: Int) -> CGFloat {
		Theme.rowPadding + CGFloat(index) * (Theme.cardSize.width + Theme.cardGap)
	}

	public static func contentWidth(count: Int) -> CGFloat {
		guard count > 0 else { return 2 * Theme.rowPadding }
		return 2 * Theme.rowPadding + CGFloat(count) * Theme.cardSize.width + CGFloat(count - 1) * Theme.cardGap
	}

	/// The scroll offset that keeps the selected card at least 24 pt from both edges, moving as little as possible.
	public static func offset(selectedMinX: CGFloat, viewport: CGFloat, current: CGFloat, contentWidth: CGFloat) -> CGFloat {
		let maxOffset = max(0, contentWidth - viewport)
		let lowest = selectedMinX + Theme.cardSize.width + Theme.scrollMargin - viewport
		let highest = selectedMinX - Theme.scrollMargin
		var target = current
		if target < lowest { target = lowest }
		if target > highest { target = highest }
		return min(max(target, 0), maxOffset)
	}
}
