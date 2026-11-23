import Testing
import AppKit
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

/// Holds each decode until the test grants a permit, so the race with `removeAll()` is deterministic.
actor DecodeGate {
	private(set) var entered = 0
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
	@Test func cancelledFirstConsumerDoesNotBlockOtherURLsOrCancelTheSharedImage() async throws {
		let held = URL(fileURLWithPath: "/fixture/held-preview"), independent = URL(fileURLWithPath: "/fixture/other-preview")
		let pixels = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
		let gate = DecodeGate()
		let cache = ThumbnailCache { url in
			if url == held { await gate.enter() }
			return pixels
		}
		let first = Task { await cache.load(held) }
		await gate.untilEntered(1)
		first.cancel()
		let survivor = Task { await cache.load(held) }, other = Task { await cache.load(independent) }
		let finishedIndependently = await eventually { cache.cached(independent) != nil }
		#expect(finishedIndependently && cache.cached(held) == nil)
		await gate.release(); await gate.release()
		_ = await first.value
		let delivered = await survivor.value, otherImage = await other.value
		#expect(delivered != nil && delivered === cache.cached(held))
		#expect(otherImage != nil && otherImage === cache.cached(independent))
		#expect(await gate.entered == 1)
		#expect(cache.decodeCount == 2)
	}

	@Test func failedDecodeCanBeRequestedAgain() async {
		let gate = DecodeGate(), url = URL(fileURLWithPath: "/fixture/retry-thumbnail")
		let cache = ThumbnailCache { _ in await gate.enter(); return nil }
		await gate.release()
		#expect(await cache.load(url) == nil)
		await gate.release()
		#expect(await cache.load(url) == nil)
		#expect(await gate.entered == 2)
		#expect(cache.entryCount == 0)
	}

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
		let fresh = Task { await cache.load(url) }
		let newGenerationStarted = await eventually { await gate.entered >= 2 }
		await gate.release()
		#expect(await stale.value == nil)
		#expect(cache.cached(url) == nil)
		#expect(cache.entryCount == 0)

		let joined = Task { @MainActor in await cache.load(url) }
		await Task.yield()
		await gate.release(); await gate.release()
		let newImage = await fresh.value, joinedImage = await joined.value
		#expect(newGenerationStarted && newImage != nil && newImage === joinedImage)
		#expect(await gate.entered == 2)
		#expect(cache.decodeCount == 1 && cache.cached(url) === newImage)
	}
}
