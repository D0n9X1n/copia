import Testing
import Foundation
import CopiaStore
@testable import CopiaBench

@Suite struct BenchSeedTests {
	/// Neighbouring text cards must look different, or a card that slides one slot matches its neighbour's slot.
	@Test func neighbouringTextClipsDifferInLength() {
		for i in 0..<40 {
			let here = Bench.seedText(i), next = Bench.seedText(i + 1)
			#expect(here.contains("item \(i) "))
			#expect(abs(here.count - next.count) > 40, "\(i): \(here.count) vs \(next.count)")
		}
	}
	@Test @MainActor func allSeedImagesHaveSavedPreviews() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("copia-seed-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = try ClipStore(directory: directory.appendingPathComponent("store"))
		try await Bench.seed(store, assets: directory.appendingPathComponent("assets"))
		let images = try await store.recent().filter { $0.kind == .image }
		#expect(images.count == 300)
		for clip in images {
			#expect(clip.previewState == .ok)
			#expect(await store.thumbnail(for: clip.key) != nil)
		}
	}

}
