import Testing
import AppKit
import CopiaUI
@testable import CopiaApp

/// The self-test's frame check, on fixed geometry: it never opens the strip or reads the real desktop.
@MainActor
@Suite struct SelfTestTests {
	/// A display left of the main one, with a negative origin and the Dock below.
	static let visible = CGRect(x: -1224, y: 80, width: 1224, height: 2176)

	@Test func theLayoutFrameInsideTheVisibleFramePasses() {
		let frame = PanelLayout.windowFrame(in: Self.visible)
		#expect(SelfTest.frameViolations(panel: frame, visible: Self.visible).isEmpty)
		// Backing-scale rounding of half a point is not a violation.
		#expect(SelfTest.frameViolations(panel: frame.offsetBy(dx: 0.25, dy: -0.25), visible: Self.visible).isEmpty)
	}

	/// Larger than the layout frame but still holding the strip, and on the screen: the old check accepted this.
	@Test func aLargerFrameThatStillHoldsTheStripFails() {
		let frame = PanelLayout.windowFrame(in: Self.visible).insetBy(dx: -4, dy: -20)
		#expect(frame.contains(PanelLayout.stripFrame(in: Self.visible)))
		#expect(!SelfTest.frameViolations(panel: frame, visible: Self.visible).isEmpty)
	}

	@Test func aLargerMispositionedFrameFails() {
		let frame = CGRect(x: Self.visible.minX, y: Self.visible.minY + 300, width: Self.visible.width + 40, height: 400)
		let problems = SelfTest.frameViolations(panel: frame, visible: Self.visible)
		#expect(problems.contains { $0.contains("not the layout frame") })
		#expect(problems.contains { $0.contains("leaves the visible frame") })
	}

	@Test func aRightSizedFrameInTheWrongPlaceFails() {
		let layout = PanelLayout.windowFrame(in: Self.visible)
		let raised = SelfTest.frameViolations(panel: layout.offsetBy(dx: 0, dy: 300), visible: Self.visible)
		#expect(raised.count == 1 && raised[0].contains("not the layout frame"))
		let belowDock = SelfTest.frameViolations(panel: layout.offsetBy(dx: 0, dy: -40), visible: Self.visible)
		#expect(belowDock.contains { $0.contains("leaves the visible frame") })
	}
}

extension WindowTests {
	@MainActor @Suite struct PackageSmokeInputTests {
		enum Interruption: CaseIterable, Sendable { case beforeTyping, afterTyping, replacedPresentation }

		@Test(arguments: Interruption.allCases) func interruptedPresentationIsNotTypedIntoOrToggledOpenAgain(_ phase: Interruption) async throws {
			let rig = try AppRig(), controller = rig.controller
			let report = rig.dir.appendingPathComponent("interrupted-smoke.json")
			defer { controller.model.beginClose() }
			var openings = 0
			controller.model.onOpenFinish = { [weak controller] in
				openings += 1
				if openings == 1, phase != .afterTyping {
					controller?.model.beginClose()
					if phase == .replacedPresentation { controller?.toggleHistory(on: NSScreen.screens.first) }
				}
			}
			let interruption = Task { @MainActor in
				guard phase == .afterTyping else { return false }
				guard await eventually({ controller.model.query == "q" }) else { return false }
				controller.model.beginClose()
				return true
			}
			let result = await SelfTest.run(controller: controller, output: report, hold: 0.15)
			#expect(await interruption.value == (phase == .afterTyping))
			let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
			let samples = try #require(json["samples"] as? [[String: Any]])
			#expect(result != 0)
			#expect(openings == (phase == .replacedPresentation ? 2 : 1) && samples.count == 1)
			let first = try #require(samples.first)
			#expect(first["typedQuery"] as? String == (phase == .afterTyping ? "q" : "<not sent>"))
			#expect(first["cardsMountedAfterClose"] as? Bool == (phase == .replacedPresentation))
			#expect(controller.panel.isVisible == (phase == .replacedPresentation))
			#expect(controller.model.cardsMounted == (phase == .replacedPresentation))
			#expect((json["violations"] as? [String])?.contains("display 0 cycle 0: history presentation interrupted") == true)
		}
	}
}
