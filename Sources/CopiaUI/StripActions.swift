import Foundation
import Observation
import CopiaCore

/// What happened when the user asked to paste.
public enum PasteResult: Sendable {
	/// Pasted into the previous app.
	case pasted
	/// Left on the clipboard without pasting (for example, the target app never came forward).
	case copied
	/// Copied, but pasting needs the Accessibility permission.
	case accessibilityRequired
}

/// The four actions a card offers. Mouse, keyboard and VoiceOver all go through these.
public enum CardAction: String, CaseIterable, Sendable {
	case paste = "Paste"
	case pastePlain = "Paste as Plain Text"
	case copy = "Copy"
	case delete = "Delete"
}

/// The side effects the strip can request. Fixtures and the real engine (B2) supply different closures.
@MainActor
public struct StripActions {
	/// Paste a clip. Call `beginClose` once the paste is allowed to proceed.
	public var paste: (_ id: UUID, _ plain: Bool, _ beginClose: @escaping @MainActor () -> Void) async throws -> PasteResult
	public var copy: (_ id: UUID) async throws -> Void
	public var delete: (_ id: UUID) async throws -> Void
	public var restore: (_ clip: Clip, _ index: Int) async throws -> Void
	public var openAccessibilitySettings: () -> Void
	/// Full-text search over everything stored, not only the card text. Returns matching clip IDs.
	public var search: (_ query: String) async -> Set<UUID> = { _ in [] }

	public init(
		paste: @escaping (UUID, Bool, @escaping @MainActor () -> Void) async throws -> PasteResult,
		copy: @escaping (UUID) async throws -> Void,
		delete: @escaping (UUID) async throws -> Void,
		restore: @escaping (Clip, Int) async throws -> Void,
		openAccessibilitySettings: @escaping () -> Void
	) {
		self.paste = paste
		self.copy = copy
		self.delete = delete
		self.restore = restore
		self.openAccessibilitySettings = openAccessibilitySettings
	}

	/// Actions that only touch in-memory fixtures; nothing reaches the system clipboard.
	public static var fixtures: StripActions {
		StripActions(
			paste: { _, _, beginClose in beginClose(); return .pasted },
			copy: { _ in },
			delete: { _ in },
			restore: { _, _ in },
			openAccessibilitySettings: {}
		)
	}
}

/// A transient message at the bottom of the strip.
public enum Toast: Equatable, Sendable {
	case deleted
	case accessibilityRequired
	case error(String)

	public var message: String {
		switch self {
		case .deleted: "Deleted · ⌘Z to undo"
		case .accessibilityRequired: "Allow Accessibility to paste"
		case let .error(text): text
		}
	}
}
