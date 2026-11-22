import Testing
@testable import CopiaBench

@Suite struct BenchPlanTests {
	@Test @MainActor func idleCPUBudgetIsPointOneFivePercentWithoutChangingOtherLimits() {
		let limit = Bench.Budgets.idleCPUPercent
		#expect(limit == 0.15)
		#expect(0.110 < limit)
		#expect(0.149 < limit)
		#expect(!(0.15 < limit))
		#expect(!(0.151 < limit))
		#expect(Bench.Budgets.idleFootprintMB == 40)
		#expect(Bench.Budgets.openFootprintMB == 120)
		#expect(Bench.Budgets.openP95ms == 100)
	}

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

	@Test func presentedFrameChecksGateOnlyAt120HzOrFaster() {
		#expect(BenchPlan.gatesPresentedFrames(refreshHz: 120))
		#expect(BenchPlan.gatesPresentedFrames(refreshHz: 119.9))
		#expect(!BenchPlan.gatesPresentedFrames(refreshHz: 75))
		#expect(!BenchPlan.gatesPresentedFrames(refreshHz: 60))
	}

	@Test func presentedFailuresGateAt120HzAndAreOnlyReportedBelow() {
		let presented = [("presentedOpenP95ms < 100.0", false), ("scrollSmoothness", true), ("motionSettle.close", false)]
		let fast = BenchPlan.route(presented: presented, refreshHz: 120)
		#expect(fast.gated.map(\.0) == presented.map(\.0))
		#expect(fast.gated.filter { !$0.1 }.count == 2)
		#expect(fast.reported.isEmpty)
		let slow = BenchPlan.route(presented: presented, refreshHz: 60)
		#expect(slow.gated.isEmpty)
		#expect(slow.reported.map(\.0) == presented.map(\.0))
	}

	@Test func theOpenGateRunsAtTheReferenceWidthUnlessAWidthIsGiven() {
		#expect(BenchPlan.referenceWidth == 1_512)
		#expect(BenchPlan.stripWidth(requested: nil, screen: 2_924) == 1_512)
		#expect(BenchPlan.stripWidth(requested: 2_000, screen: 2_924) == 2_000)
		#expect(BenchPlan.stripWidth(requested: nil, screen: 1_280) == 1_280)
	}

	@Test func recordedChecksCoverScrollAndEveryMotion() {
		#expect(BenchPlan.recordedChecks.contains("scrollSmoothness"))
		for event in ["open", "close", "lens", "delete", "undo"] {
			#expect(BenchPlan.recordedChecks.contains("motionSettle.\(event)"))
			#expect(BenchPlan.recordedChecks.contains("motionSettle.\(event).reduced"))
		}
	}
}
