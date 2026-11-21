import SwiftUI

/// Every animated transition in the strip.
public enum MotionEvent: CaseIterable, Sendable {
	case open, close, lens, delete, reflow, undo, insert, loading
}

/// An animation curve from the design brief's "Motion" section.
public enum MotionCurve: Equatable, Sendable {
	case none
	case spring(response: Double, damping: Double)
	case easeIn(Double)
	case easeInOut(Double)
	case linear(Double)

	var animation: Animation? {
		switch self {
		case .none: nil
		case let .spring(response, damping): .spring(response: response, dampingFraction: damping)
		case let .easeIn(duration): .easeIn(duration: duration)
		case let .easeInOut(duration): .easeInOut(duration: duration)
		case let .linear(duration): .linear(duration: duration)
		}
	}
}

/// The one table every animation reads from.
public enum Motion {
	public static func value(_ event: MotionEvent, reduced: Bool) -> MotionCurve {
		if reduced {
			// Reduce Motion: open/close fade in place, the lens jumps, inserts and deletes crossfade.
			return event == .lens ? .none : .linear(0.15)
		}
		switch event {
		case .open: return .spring(response: 0.32, damping: 0.86)
		case .close: return .easeIn(0.18)
		case .lens: return .spring(response: 0.22, damping: 0.9)
		case .delete, .undo: return .easeInOut(0.2)
		case .reflow, .insert: return .spring(response: 0.3, damping: 0.9)
		case .loading: return .linear(0.15)
		}
	}
}

/// The strip's open/close and card insert/delete values. Views read these; the curves come from `Motion`.
public enum StripMotion {
	public enum CardTransition: Equatable, Sendable { case crossfade, slideIn, reverseDelete }

	public static let deleteScale: CGFloat = 0.9

	/// Open slides up from fully below the window (its whole height); Reduce Motion fades in place.
	public static func openOffset(appeared: Bool, reduced: Bool) -> CGFloat {
		appeared || reduced ? 0 : Theme.panelHeight
	}

	/// Only Reduce Motion fades; the slide alone hides the strip otherwise.
	public static func openOpacity(appeared: Bool, reduced: Bool) -> Double {
		appeared || !reduced ? 1 : 0
	}

	/// A deleting card shrinks as it fades; Reduce Motion only crossfades.
	public static func removingScale(removing: Bool, reduced: Bool) -> CGFloat {
		removing && !reduced ? deleteScale : 1
	}

	/// New copies slide in at the front; an undone card comes back with the reverse of its delete.
	public static func cardTransition(returning: Bool, reduced: Bool) -> CardTransition {
		reduced ? .crossfade : (returning ? .reverseDelete : .slideIn)
	}

	/// A card's identity in the row.
	public struct CardKey: Hashable, Sendable {
		let id: UUID
		let slot: Int?
	}

	/// Under Reduce Motion the slot is part of the identity: a card that changes slot crossfades out of the old one
	/// and into the new one instead of sliding across.
	public static func cardKey(id: UUID, slot: Int, reduced: Bool) -> CardKey {
		CardKey(id: id, slot: reduced ? slot : nil)
	}
}

/// Runs a state change under its table animation, then calls `completion`. Tests inject a recording spy.
@MainActor
public struct Animator {
	public var run: (_ event: MotionEvent, _ change: () -> Void, _ completion: @escaping @MainActor () -> Void) -> Void

	public init(run: @escaping (MotionEvent, () -> Void, @escaping @MainActor () -> Void) -> Void) {
		self.run = run
	}

	public static func live(reduced: @escaping @MainActor () -> Bool = {
		NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
	}) -> Animator {
		Animator { event, change, completion in
			guard let animation = Motion.value(event, reduced: reduced()).animation else {
				change()
				completion()
				return
			}
			withAnimation(animation, completionCriteria: .logicallyComplete, change, completion: completion)
		}
	}

	/// Applies every change at once. Used by tests and the render harness.
	public static var immediate: Animator {
		Animator { _, change, completion in
			change()
			completion()
		}
	}
}

/// Schedules toast expiry. Tests inject a manual clock.
@MainActor
public struct ToastClock {
	public typealias Cancel = @MainActor () -> Void
	public var after: (Duration, @escaping @MainActor () -> Void) -> Cancel

	public init(after: @escaping (Duration, @escaping @MainActor () -> Void) -> Cancel) {
		self.after = after
	}

	public static var live: ToastClock {
		ToastClock { delay, action in
			let task = Task { @MainActor in
				try? await Task.sleep(for: delay)
				if !Task.isCancelled { action() }
			}
			return { task.cancel() }
		}
	}
}
