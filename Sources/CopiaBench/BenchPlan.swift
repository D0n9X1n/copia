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

	static func skips(path: Path, screenRecording: Bool) -> [Skip] {
		guard path == .proxy else { return [] }
		let reason = screenRecording ? "--no-sck: recorded checks were turned off"
			: "no Screen Recording permission: recorded checks need ScreenCaptureKit"
		return recordedChecks.map { Skip(check: $0, reason: reason) }
	}
}
