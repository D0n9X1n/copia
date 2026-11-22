import Foundation

struct ClipIndex {
	private(set) var keys: [UUID: String] = [:]
	private(set) var mutations = 0
	private var groups: [UUID: Set<UUID>] = [:]
	private var ended: Set<UUID> = []

	@discardableResult
	mutating func apply(_ snapshot: [UUID: String], fetchedAt: Int) -> Bool {
		guard fetchedAt == mutations else { return false }
		keys = snapshot
		for (token, ids) in groups where ids.contains(where: { snapshot[$0] != nil }) {
			ended.formUnion(ids)
			groups[token] = nil
		}
		return true
	}

	mutating func noteChanged() { mutations += 1 }

	mutating func noteDeleted(_ ids: [UUID], token: UUID) {
		noteChanged()
		for id in ids { keys[id] = nil }
		groups[token] = Set(ids)
	}

	func canRestore(_ token: UUID) -> Bool { groups[token] != nil }
	mutating func forget(_ token: UUID) { groups[token] = nil }
	mutating func clearDeletions() { groups.removeAll() }

	mutating func noteRestored(_ token: UUID, keys restored: [UUID: String]) {
		noteChanged()
		forget(token)
		keys.merge(restored) { _, new in new }
	}

	mutating func noteErased() {
		noteChanged()
		keys.removeAll()
		for ids in groups.values { ended.formUnion(ids) }
		clearDeletions()
	}

	mutating func takeEndedUndos() -> Set<UUID> {
		defer { ended.removeAll() }
		return ended
	}
}
