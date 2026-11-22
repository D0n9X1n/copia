import Foundation
import Observation
import CopiaCore

/// Storage diagnostics survive transient toasts and are shared by the strip and Settings.
public enum StorageStatus: Equatable, Sendable {
	case ready, cleanupPending, recoveryRequired

	public var message: String {
		switch self {
		case .ready: ""
		case .cleanupPending: "Some saved files are awaiting cleanup. Copia will retry."
		case .recoveryRequired: "Outcome unknown; capture paused until restart. Restart Copia to recover."
		}
	}
}

/// An indeterminate database outcome must not be presented as a rolled-back operation.
public enum StripActionError: Error { case outcomeUnknown, undoExpired }

/// The menu and VoiceOver use the same labels and dispatch.
public enum CardAction: String, CaseIterable, Sendable {
	case activate = "Copy and Close"
	case copyPlain = "Copy as Plain Text and Close"
	case copy = "Copy"
	case pin = "Pin"
	case delete = "Delete"

	func label(for clip: Clip) -> String { self == .pin && clip.isPinned ? "Unpin" : rawValue }
}

/// Engine effects. Tests and render scenes can override just the operation they exercise.
@MainActor
public struct StripActions {
	public var write: (UUID, Bool) async throws -> Void = { _, _ in }
	public var delete: ([UUID]) async throws -> UUID = { _ in UUID() }
	public var restore: (UUID) async throws -> [Clip] = { _ in throw StripActionError.undoExpired }
	public var setPinned: (UUID, Bool) async throws -> Void = { _, _ in }
	public var openSettings: () -> Void = {}
	public var search: (String) async -> Set<UUID> = { _ in [] }

	public static var fixtures: Self { Self() }
}

/// A transient message at the bottom of the strip.
public enum Toast: Equatable, Sendable {
	case deleted
	case error(String)

	public var message: String {
		switch self {
		case .deleted: "Deleted · ⌘Z to undo"
		case let .error(text): text
		}
	}
}
