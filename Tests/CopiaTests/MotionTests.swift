import Testing
import Foundation
@testable import CopiaUI

@Suite struct MotionTests {
	@Test func normalPlaybackKeepsTheOriginalSpringShapes() {
		#expect(Motion.value(.open, reduced: false) == .spring(response: 0.23, damping: 0.86))
		#expect(Motion.value(.close, reduced: false) == .easeIn(0.125))
		#expect(Motion.value(.lens, reduced: false) == .spring(response: 0.16, damping: 0.9))
		#expect(Motion.value(.delete, reduced: false) == .easeInOut(0.2))
		#expect(Motion.value(.reflow, reduced: false) == .spring(response: 0.16, damping: 0.9))
		#expect(Motion.value(.loading, reduced: false) == .linear(0.15))
	}

	@Test func reducedMotionFollowsBrief() {
		#expect(Motion.value(.lens, reduced: true) == .none)
		for event in [MotionEvent.open, .close, .undo] { #expect(Motion.value(event, reduced: true) == .linear(0.105)) }
		#expect(Motion.value(.reflow, reduced: true) == .linear(0.08))
		for event in [MotionEvent.delete, .insert, .loading] { #expect(Motion.value(event, reduced: true) == .linear(0.15)) }
	}

	@Test func livePlaybackHasHeadroomInsideThePublishedMotionBudget() {
		for event in [MotionEvent.open, .close, .lens, .undo, .reflow] {
			let live = Motion.value(event, reduced: false), ceiling = Motion.settleCeiling(event, reduced: false)
			switch (live, ceiling) {
			case let (.spring(t, damping), .spring(limit, originalDamping)):
				#expect(t < limit && damping == originalDamping)
			case let (.easeIn(t), .easeIn(limit)), let (.easeInOut(t), .easeInOut(limit)):
				#expect(t < limit)
			default: Issue.record("Changed the shape of \(event) instead of shortening its duration")
			}
		}
		#expect(Motion.value(.lens, reduced: true) == .none)
		#expect(Motion.settleCeiling(.open, reduced: false) == .spring(response: 0.32, damping: 0.86))
		#expect(Motion.settleCeiling(.close, reduced: true) == .linear(0.15))
		#expect(Motion.settleCeiling(.reflow, reduced: false) == .spring(response: 0.3, damping: 0.9))
		#expect(Motion.settleCeiling(.reflow, reduced: true) == .linear(0.15))
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
		#expect(Motion.value(.open, reduced: true) == .linear(0.105))
		#expect(Motion.value(.close, reduced: true) == .linear(0.105))
	}

	@Test func reduceMotionDeletesAndInsertsOnlyCrossfade() {
		#expect(StripMotion.removingScale(removing: true, reduced: false) == StripMotion.deleteScale)
		#expect(StripMotion.deleteScale == 0.9)
		#expect(StripMotion.removingScale(removing: false, reduced: false) == 1)
		#expect(StripMotion.removingScale(removing: true, reduced: true) == 1)
		#expect(StripMotion.cardTransition(returning: false, reduced: true) == .crossfade)
		#expect(StripMotion.cardTransition(returning: true, reduced: true) == .crossfade)
	}

	@Test func reduceMotionNeighboursCrossfadeToTheirNewSlotInsteadOfSliding() {
		let id = UUID()
		// A card whose slot changes gets a new identity, so it fades out in place and fades in at the new slot.
		#expect(StripMotion.cardKey(id: id, slot: 2, reduced: true) != StripMotion.cardKey(id: id, slot: 1, reduced: true))
		#expect(StripMotion.cardKey(id: id, slot: 1, reduced: true) == StripMotion.cardKey(id: id, slot: 1, reduced: true))
		// With motion, a card keeps its identity and slides.
		#expect(StripMotion.cardKey(id: id, slot: 2, reduced: false) == StripMotion.cardKey(id: id, slot: 1, reduced: false))
		#expect(StripMotion.cardKey(id: id, slot: 0, reduced: false) != StripMotion.cardKey(id: UUID(), slot: 0, reduced: false))
	}

	@Test func newCopiesSlideInAndUndoReversesTheDelete() {
		#expect(StripMotion.cardTransition(returning: false, reduced: false) == .slideIn)
		#expect(StripMotion.cardTransition(returning: true, reduced: false) == .reverseDelete)
	}
}
