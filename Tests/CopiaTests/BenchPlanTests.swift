import Testing
@testable import CopiaBench

@Suite struct BenchPlanTests {
	@Test func screenCaptureKitRunsOnlyWithScreenRecordingAndNoOptOut() {
		#expect(BenchPlan.path(screenRecording: true, noSCK: false) == .screenCaptureKit)
		#expect(BenchPlan.path(screenRecording: false, noSCK: false) == .proxy)
		#expect(BenchPlan.path(screenRecording: true, noSCK: true) == .proxy)
		#expect(BenchPlan.path(screenRecording: false, noSCK: true) == .proxy)
	}

	@Test func theProxyPathSkipsEveryRecordedCheckWithAReason() {
		let skips = BenchPlan.skips(path: .proxy, screenRecording: false)
		#expect(Set(skips.map(\.check)) == Set(BenchPlan.recordedChecks))
		#expect(skips.allSatisfy { $0.reason.contains("Screen Recording") })
	}

	@Test func anOptOutIsNamedAsTheReason() {
		let skips = BenchPlan.skips(path: .proxy, screenRecording: true)
		#expect(skips.count == BenchPlan.recordedChecks.count)
		#expect(skips.allSatisfy { $0.reason.contains("--no-sck") })
	}

	@Test func theScreenCaptureKitPathSkipsNothing() {
		#expect(BenchPlan.skips(path: .screenCaptureKit, screenRecording: true).isEmpty)
	}

	@Test func recordedChecksCoverScrollAndEveryMotion() {
		#expect(BenchPlan.recordedChecks.contains("scrollSmoothness"))
		for event in ["open", "close", "lens", "delete", "undo"] {
			#expect(BenchPlan.recordedChecks.contains("motionSettle.\(event)"))
			#expect(BenchPlan.recordedChecks.contains("motionSettle.\(event).reduced"))
		}
	}
}
