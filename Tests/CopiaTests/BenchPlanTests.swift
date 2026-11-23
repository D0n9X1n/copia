import Testing
import AppKit
@testable import CopiaBench

@Suite struct BenchPlanTests {
	@Test @MainActor func idleCPUUsesTheStrictPointTwoPercentBudget() {
		#expect(Bench.Budgets.idleCPUPercent == 0.20)
		#expect(Bench.Budgets.acceptsIdleCPU(0.189))
		#expect(Bench.Budgets.acceptsIdleCPU(0.1999))
		#expect(!Bench.Budgets.acceptsIdleCPU(0.20))
		#expect(!Bench.Budgets.acceptsIdleCPU(0.201))
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
		#expect(BenchPlan.recordedChecks.contains("pointerSelection.presentedTargetRing"))
		for event in ["open", "close", "lens", "delete", "undo"] {
			#expect(BenchPlan.recordedChecks.contains("motionSettle.\(event)"))
			#expect(BenchPlan.recordedChecks.contains("motionSettle.\(event).reduced"))
		}
	}
}

extension WindowTests {
	@MainActor @Suite struct RecordedMotionTests {
		@Test func anInterruptedTrialCannotScoreOrReopenTheHiddenFixture() async throws {
			let rig = try AppRig(), panel = rig.controller.panel
			try await rig.copy("owned motion fixture")
			panel.alphaValue = 0
			panel.setFrame(CGRect(x: -6000, y: -6000, width: 1000, height: 316), display: false)
			defer { panel.orderOut(nil) }
			func open() { rig.controller.model.open(); panel.orderFrontRegardless(); panel.makeKey() }
			let run = RecordedRun(controller: rig.controller, recorder: Recorder(width: 200, height: 200),
				wallpaper: Wallpaper(behind: panel), refresh: 1 / 120)
			let peer = NSWindow(contentRect: panel.frame, styleMask: .titled, backing: .buffered, defer: false)
			peer.alphaValue = 0; peer.isReleasedWhenClosed = false
			defer { peer.orderOut(nil) }
			open(); try #require(panel.isKeyWindow && panel.isVisible)
			let interrupted = await run.trial(.lens, seconds: 0) { peer.makeKeyAndOrderFront(nil) }
			#expect(interrupted.trigger == nil && !rig.controller.model.cardsMounted)
			#expect(run.motionInterruptions["lens"] == [1])
			var invoked = false
			let close = await run.trial(.close, seconds: 0) { invoked = true; open() }
			#expect(!invoked && close.trigger == nil && !panel.isVisible)
			#expect(run.motionInterruptions["close"] == [1])
			open(); await Task.yield()
			_ = await run.trial(.close, seconds: 0) { rig.controller.model.beginClose() }
			#expect(!panel.isVisible && run.motionInterruptions["close"] == [1])
		}

		@Test(.enabled(if: CGPreflightScreenCaptureAccess()))
		func anInterruptedRecordedAnimationDropsARealStartTime() async throws {
			let rig = try AppRig(), controller = rig.controller
			try await rig.copy("first timing fixture")
			try await rig.copy("second timing fixture")
			let firstID = try #require(controller.model.visibleClips.first?.id)
			let run = try await RecordedRun.start(controller)
			let model = controller.model, panel = controller.panel
			let peer = NSWindow(contentRect: panel.frame, styleMask: .titled, backing: .buffered, defer: false)
			peer.alphaValue = 0; peer.isReleasedWhenClosed = false
			defer { peer.orderOut(nil) }
			let opened = await run.trial(.open, seconds: 0.6) { controller.toggleHistory() }
			#expect(opened.trigger != nil)
			model.selectOnPress(firstID)
			let valid = await run.trial(.lens, seconds: 0.3) { model.move(1) }
			#expect(valid.trigger != nil && model.selectedIndex == 1)
			let interrupted = await run.trial(.lens, seconds: 0.4) {
				model.move(-1)
				#expect(model.selectedIndex == 0)
				peer.makeKeyAndOrderFront(nil)
			}
			#expect(interrupted.trigger == nil && run.motionInterruptions["lens"] == [1])
			#expect(!model.cardsMounted && !panel.isVisible)
			_ = await run.trial(.open, seconds: 0.6) { controller.toggleHistory() }
			let intentionalClose = await run.trial(.close, seconds: 0.6) { model.beginClose() }
			#expect(intentionalClose.trigger != nil && run.motionInterruptions["close"] == nil)
			await run.finish()
		}
	}
}
