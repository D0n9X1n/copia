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

	@Test func openSlidesUpFromBelowItsFullHeightWithoutAFade() {
		#expect(StripMotion.openOffset(appeared: false, reduced: false) >= Theme.panelHeight)
		#expect(StripMotion.openOffset(appeared: true, reduced: false) == 0)
		#expect(StripMotion.openOpacity(appeared: false, reduced: false) == 1)
	}

	@Test func reduceMotionOpensAndClosesWithAFadeInPlace() {
		#expect(StripMotion.openOffset(appeared: false, reduced: true) == 0)
		#expect(StripMotion.openOpacity(appeared: false, reduced: true) == 0)
		#expect(StripMotion.openOpacity(appeared: true, reduced: true) == 1)
		#expect(Motion.value(.open, reduced: true) == .linear(0.15))
		#expect(Motion.value(.close, reduced: true) == .linear(0.15))
	}

	@Test func reduceMotionDeletesAndInsertsOnlyCrossfade() {
		#expect(StripMotion.removingScale(removing: true, reduced: false) == StripMotion.deleteScale)
		#expect(StripMotion.deleteScale == 0.9)
		#expect(StripMotion.removingScale(removing: false, reduced: false) == 1)
		#expect(StripMotion.removingScale(removing: true, reduced: true) == 1)
		#expect(StripMotion.cardTransition(returning: false, reduced: true) == .crossfade)
		#expect(StripMotion.cardTransition(returning: true, reduced: true) == .crossfade)
	}

	@Test func newCopiesSlideInAndUndoReversesTheDelete() {
		#expect(StripMotion.cardTransition(returning: false, reduced: false) == .slideIn)
		#expect(StripMotion.cardTransition(returning: true, reduced: false) == .reverseDelete)
	}
}
