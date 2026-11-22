import SwiftUI
import CopiaUI

/// The analytic time each strip motion takes to come within 1% of its target, from the `Motion` table.
enum SettleBudget {
	/// "Settled" means within 1% of the target.
	static let tolerance = 0.01
	/// Measured settle time may exceed the analytic one by this much.
	static let margin = 0.020
	static let events: [MotionEvent] = [.open, .close, .lens, .delete, .undo]

	/// Seconds from the start of `curve` until it is last more than 1% away from its target.
	static func settle(_ curve: MotionCurve) -> Double {
		switch curve {
		case .none: 0
		case let .linear(duration): duration * (1 - tolerance)
		case let .easeIn(duration): duration * crossing(.easeIn)
		case let .easeInOut(duration): duration * crossing(.easeInOut)
		case let .spring(response, damping): springSettle(Spring(response: response, dampingRatio: damping))
		}
	}

	/// A delete starts reflow from the fade completion. Budget the full fade, then the reflow's settle time;
	/// the budget follows that scheduled sequence rather than assuming the animations overlap.
	static func analytic(_ event: MotionEvent, reduced: Bool) -> Double {
		let curve = Motion.settleCeiling(event, reduced: reduced)
		guard event == .delete else { return settle(curve) }
		return logicalDuration(curve) + settle(Motion.settleCeiling(.reflow, reduced: reduced))
	}

	static func limit(_ event: MotionEvent, reduced: Bool) -> Double {
		analytic(event, reduced: reduced) + margin
	}

	/// The end of a timed curve, when its logically-complete callback can start the next animation.
	private static func logicalDuration(_ curve: MotionCurve) -> Double {
		switch curve {
		case .none: 0
		case let .linear(duration), let .easeIn(duration), let .easeInOut(duration): duration
		case .spring: settle(curve)
		}
	}

	/// The unit time at which a monotonic curve reaches 1 - tolerance.
	private static func crossing(_ curve: UnitCurve) -> Double {
		var low = 0.0, high = 1.0
		for _ in 0..<60 {
			let mid = (low + high) / 2
			if curve.value(at: mid) < 1 - tolerance { low = mid } else { high = mid }
		}
		return high
	}

	/// The last time a spring from rest toward 1 is more than `tolerance` away, scanned at 0.1 ms.
	private static func springSettle(_ spring: Spring) -> Double {
		let step = 0.0001
		var last = 0.0
		for i in 0...50_000 {
			let t = Double(i) * step
			if abs(1 - spring.value(target: 1.0, time: t)) > tolerance { last = t }
		}
		return last + step
	}
}
