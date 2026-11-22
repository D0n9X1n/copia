import Testing
import AppKit
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

/// Holds each decode until the test grants a permit, so the race with `removeAll()` is deterministic.
actor DecodeGate {
	private var entered = 0
	private var permits = 0
	private var waiting: [CheckedContinuation<Void, Never>] = []
	private var watchers: [(count: Int, resume: CheckedContinuation<Void, Never>)] = []

	func enter() async {
		entered += 1
		for watcher in watchers where watcher.count <= entered { watcher.resume.resume() }
		watchers.removeAll { $0.count <= entered }
		if permits > 0 { permits -= 1; return }
		await withCheckedContinuation { waiting.append($0) }
	}

	/// Returns once `count` decodes have started.
	func untilEntered(_ count: Int) async {
		if entered >= count { return }
		await withCheckedContinuation { watchers.append((count, $0)) }
	}

	func release() {
		if waiting.isEmpty { permits += 1 } else { waiting.removeFirst().resume() }
	}
}

@MainActor
@Suite struct ThumbnailCacheTests {
	@Test func aDecodeThatLandsAfterRemoveAllDoesNotRepopulate() async throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-thumb-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let assets = try FixtureAssets.prepare(in: dir)
		guard case let .ready(url) = assets.mixed[3].preview else { Issue.record("no preview"); return }
		let gate = DecodeGate()
		let cache = ThumbnailCache(decode: { url in
			await gate.enter()
			return ThumbnailCache.decode(url)
		})
		let stale = Task { await cache.load(url) }
		await gate.untilEntered(1)
		cache.removeAll()
		await gate.release()
		#expect(await stale.value == nil)
		#expect(cache.cached(url) == nil)
		#expect(cache.entryCount == 0)

		// A load that starts after the purge caches normally. The permit is granted up front so a cache hit cannot hang.
		await gate.release()
		#expect(await cache.load(url) != nil)
		#expect(cache.cached(url) != nil)
	}
}
