import Testing
import Foundation
import CopiaCore
import CopiaFixtures

@Test func fixturesCoverEveryKindAndExtremes() {
	#expect(Set(Fixtures.mixed.map(\.kind)) == Set(ClipKind.allCases))
	#expect(Fixtures.mixed.count == 9)
	#expect(Fixtures.mixed.contains { $0.isCode })
	#expect(Set(Fixtures.tenThousand.map(\.id)).count == 10_000)
	#expect(Fixtures.extremes.contains { $0.text.count == 50_000 })
	#expect(Fixtures.extremes.contains { $0.text.count == 1 })
	#expect(Fixtures.extremes.contains { $0.fileNames.count == 300 })
	#expect(Fixtures.extremes.contains { $0.sourceBundleID == nil })
	#expect(Fixtures.failed.preview == .failed)
	#expect(Fixtures.pending.preview == .pending)
}

@Test func fixtureFamiliesHaveDisjointIDs() {
	let families = [Fixtures.mixed, Fixtures.extremes, [Fixtures.failed, Fixtures.pending]]
	let all = families.flatMap { $0.map(\.id) }
	#expect(Set(all).count == all.count)
}

@Test func extremesCoverTheBriefsList() {
	let texts = Fixtures.extremes.map(\.text)
	#expect(texts.contains { $0.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } })
	#expect(texts.contains { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } })
	#expect(texts.contains { $0.unicodeScalars.contains { $0.value == 0x200D } })
	#expect(Fixtures.extremes.contains { $0.kind == .link && !$0.text.contains(" ") && $0.text.count > 100 })
	#expect(Fixtures.extremes.contains { $0.meta.hasPrefix("8000×8000") })
	#expect(Fixtures.extremes.contains { $0.meta.contains("transparent") })
	#expect(Set(Fixtures.extremes.compactMap(\.colorHex)).isSuperset(of: ["#FFFFFF", "#000000"]))
}

@Test func renderAssetsGiveFilesSavedThumbnailsAndALinkASiteIcon() throws {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-fixtures-\(UUID().uuidString)")
	defer { try? FileManager.default.removeItem(at: dir) }
	func isIcon(_ clip: Clip) -> Bool { if case .icon = clip.preview { true } else { false } }

	// The default stays as it was, so the bench and README media are unchanged.
	let plain = try FixtureAssets.prepare(in: dir)
	#expect((plain.mixed + plain.extremes).filter { $0.kind == .file }.allSatisfy { $0.preview == .pending })
	#expect(plain.extremes.contains { $0.kind == .link && isIcon($0) })

	let rich = try FixtureAssets.prepare(in: dir, filePreviews: true)
	let files = (rich.mixed + rich.extremes).filter { $0.kind == .file }
	#expect(!files.isEmpty)
	for clip in files {
		guard case let .ready(url) = clip.preview else { Issue.record("\(clip.text) has no thumbnail"); continue }
		#expect(FileManager.default.fileExists(atPath: url.path))
	}
	for case let .icon(url) in rich.extremes.map(\.preview) {
		#expect(FileManager.default.fileExists(atPath: url.path))
	}
}
