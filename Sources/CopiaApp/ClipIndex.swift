import Foundation

/// Which stored key backs each card, and which deletions can still be undone.
/// `mutations` counts deletes and restores, so a reload fetched before one of them is not applied.
struct ClipIndex<Deletion> {
	private(set) var keys: [UUID: String] = [:]
	private var deleted: [UUID: Deletion] = [:]
	private(set) var mutations = 0

	/// Applies a snapshot fetched when `mutations` was `fetchedAt`. Returns false, changing nothing, if it is stale.
	@discardableResult
	mutating func apply(_ snapshot: [UUID: String], fetchedAt: Int) -> Bool {
		guard fetchedAt == mutations else { return false }
		keys = snapshot
		// A recopy of a deleted item ends its undo.
		for id in deleted.keys where snapshot[id] != nil { deleted[id] = nil }
		return true
	}

	mutating func noteDeleted(_ id: UUID, _ deletion: Deletion) {
		mutations += 1
		keys[id] = nil
		deleted[id] = deletion
	}

	func deletion(for id: UUID) -> Deletion? { deleted[id] }

	mutating func noteRestored(_ id: UUID, key: String) {
		mutations += 1
		keys[id] = key
		deleted[id] = nil
	}

	/// Closing the strip empties the trash, so nothing is left to undo.
	mutating func clearDeletions() { deleted.removeAll() }

	/// Erasing history removes every row and the trash; a reload fetched before it is stale.
	mutating func noteErased() {
		mutations += 1
		keys.removeAll()
		deleted.removeAll()
	}
}
