/// The hidden-strip rendering budget: nothing renders while hidden, and a forced redraw proves the counters work.
enum HiddenRender {
	struct Counters: Equatable, Sendable {
		let bodies: Int
		let layerDisplays: Int
		let displayLinkTicks: Int
	}

	struct Result: Equatable {
		let failures: [String]
		var passes: Bool { failures.isEmpty }
	}

	/// `idle`: counters over the idle window. `control`: counters after a forced redraw while hidden.
	static func evaluate(idle: Counters, windowsOnScreen: Int, control: Counters) -> Result {
		var failures: [String] = []
		if idle.bodies != 0 { failures.append("hiddenBodies") }
		if idle.layerDisplays != 0 { failures.append("hiddenLayerDisplays") }
		if idle.displayLinkTicks != 0 { failures.append("hiddenDisplayLinkTicks") }
		if windowsOnScreen != 0 { failures.append("hiddenWindowsOnScreen") }
		// Without a rise the counters prove nothing, so the bench fails.
		if control.bodies == 0 || control.layerDisplays == 0 { failures.append("hiddenControlRises") }
		return Result(failures: failures)
	}
}
