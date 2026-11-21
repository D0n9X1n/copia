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
