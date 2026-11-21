import Testing
@testable import CopiaUI

@Suite struct MotionTests {
	@Test func normalTableMatchesBrief() {
		#expect(Motion.value(.open, reduced: false) == .spring(response: 0.32, damping: 0.86))
		#expect(Motion.value(.close, reduced: false) == .easeIn(0.18))
		#expect(Motion.value(.lens, reduced: false) == .spring(response: 0.22, damping: 0.9))
		#expect(Motion.value(.delete, reduced: false) == .easeInOut(0.2))
		#expect(Motion.value(.reflow, reduced: false) == .spring(response: 0.3, damping: 0.9))
		#expect(Motion.value(.loading, reduced: false) == .linear(0.15))
	}

	@Test func reducedMotionFollowsBrief() {
		#expect(Motion.value(.lens, reduced: true) == .none)
		for event in MotionEvent.allCases where event != .lens {
			#expect(Motion.value(event, reduced: true) == .linear(0.15))
		}
	}

	@Test func everyEventHasAnEntry() {
		#expect(MotionEvent.allCases.count == 8)
	}
}
