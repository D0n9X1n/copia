/// Which measurement path runs, and which checks are skipped (with a reason) when it is the proxy.
enum BenchPlan {
	enum Path: String, Equatable {
		/// Presented frames of the bench's own windows, recorded with ScreenCaptureKit.
		case screenCaptureKit
		/// In-process proxy: the panel on screen with its first card's layer contents committed.
		case proxy
	}

	struct Skip: Equatable {
		let check: String
		let reason: String
	}

	/// Checks that need recorded frames, so they only run on the ScreenCaptureKit path.
	static let recordedChecks: [String] = ["scrollSmoothness"]
		+ ["open", "close", "lens", "delete", "undo"].flatMap { ["motionSettle.\($0)", "motionSettle.\($0).reduced"] }

	static func path(screenRecording: Bool, noSCK: Bool) -> Path {
		screenRecording && !noSCK ? .screenCaptureKit : .proxy
	}

	/// Presented-frame checks (open, scroll, motion) gate only on a main display at 120 Hz or faster; on a slower display
	/// they are measured and reported (Amendment 11). Half a hertz of slack absorbs a refresh measured as 119.9 Hz.
	static func gatesPresentedFrames(refreshHz: Double) -> Bool { refreshHz >= 119.5 }

	/// Splits presented-frame checks into those that gate the run and those only reported, by the display's refresh.
	static func route(presented: [(String, Bool)], refreshHz: Double) -> (gated: [(String, Bool)], reported: [(String, Bool)]) {
		gatesPresentedFrames(refreshHz: refreshHz) ? (presented, []) : ([], presented)
	}

	/// The strip width every run measures at, a 14-inch MacBook Pro's screen, so local and CI results compare (Amendment 11).
	static let referenceWidth = 1_512.0

	static func stripWidth(requested: Double?, screen: Double) -> Double { min(requested ?? referenceWidth, screen) }

	static func skips(path: Path, screenRecording: Bool) -> [Skip] {
		guard path == .proxy else { return [] }
		let reason = screenRecording ? "--no-sck: recorded checks were turned off"
			: "no Screen Recording permission: recorded checks need ScreenCaptureKit"
		return recordedChecks.map { Skip(check: $0, reason: reason) }
	}
}
