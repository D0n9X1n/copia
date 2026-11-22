/// Rendering counters for the hidden-strip budget: they must stay at zero while the strip is hidden.
/// Incremented from view bodies, the panel's counting root layer and any display link.
@MainActor
public enum Diagnostics {
	public private(set) static var bodyEvaluations = 0
	public private(set) static var layerDisplays = 0
	public private(set) static var displayLinkTicks = 0

	public static func body() { bodyEvaluations += 1 }
	public static func layerDisplay() { layerDisplays += 1 }
	public static func displayLinkTick() { displayLinkTicks += 1 }

	public static var total: Int { bodyEvaluations + layerDisplays + displayLinkTicks }

	public static func reset() {
		bodyEvaluations = 0
		layerDisplays = 0
		displayLinkTicks = 0
	}
}
