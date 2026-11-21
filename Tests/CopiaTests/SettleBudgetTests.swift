import Testing
import Foundation
import CopiaUI
@testable import CopiaBench

@Suite struct SettleBudgetTests {
	/// The classic underdamped step response's distance from its target, an oracle independent of SwiftUI.
	static func springError(_ t: Double, response: Double, damping: Double) -> Double {
		let w0 = 2 * Double.pi / response
		let wd = w0 * (1 - damping * damping).squareRoot()
		let ratio = damping / (1 - damping * damping).squareRoot()
		return exp(-damping * w0 * t) * (cos(wd * t) + ratio * sin(wd * t))
	}

	@Test func noAnimationSettlesAtOnce() {
		#expect(SettleBudget.settle(.none) == 0)
	}

	@Test func linearSettlesAtNinetyNinePercentOfItsDuration() {
		#expect(abs(SettleBudget.settle(.linear(0.15)) - 0.1485) < 1e-9)
	}

	@Test func timingCurvesSettleJustBeforeTheirEnd() {
		let easeIn = SettleBudget.settle(.easeIn(0.18))
		#expect(easeIn > 0.17 && easeIn < 0.18)
		let easeInOut = SettleBudget.settle(.easeInOut(0.2))
		#expect(easeInOut > 0.18 && easeInOut < 0.2)
	}

	@Test func aSpringSettlesWhenItLastLeavesTheOnePercentBand() {
		for (response, damping) in [(0.32, 0.86), (0.22, 0.9), (0.3, 0.9)] {
			let settle = SettleBudget.settle(.spring(response: response, damping: damping))
			#expect(settle > 0.1 && settle < 0.6)
			#expect(abs(Self.springError(settle - 0.002, response: response, damping: damping)) > 0.01)
			for ms in 1...2_000 {
				#expect(abs(Self.springError(settle + Double(ms) / 1_000, response: response, damping: damping)) <= 0.01)
			}
		}
	}

	@Test func eventBudgetsComeFromTheMotionTable() {
		#expect(SettleBudget.analytic(.open, reduced: false) == SettleBudget.settle(Motion.value(.open, reduced: false)))
		#expect(SettleBudget.analytic(.close, reduced: false) == SettleBudget.settle(.easeIn(0.18)))
		#expect(SettleBudget.analytic(.lens, reduced: true) == 0)
		#expect(abs(SettleBudget.analytic(.undo, reduced: true) - 0.1485) < 1e-9)
	}

	@Test func aDeleteSettlesAfterItsFadeAndTheReflowThatFollows() {
		let reflow = SettleBudget.settle(Motion.value(.reflow, reduced: false))
		#expect(abs(SettleBudget.analytic(.delete, reduced: false) - (0.2 + reflow)) < 1e-9)
		#expect(abs(SettleBudget.analytic(.delete, reduced: true) - (0.15 + 0.1485)) < 1e-9)
	}

	@Test func theLimitAddsTwentyMilliseconds() {
		for event in SettleBudget.events {
			for reduced in [false, true] {
				#expect(abs(SettleBudget.limit(event, reduced: reduced) - SettleBudget.analytic(event, reduced: reduced) - 0.020) < 1e-9)
			}
		}
		#expect(SettleBudget.events == [.open, .close, .lens, .delete, .undo])
	}
}
