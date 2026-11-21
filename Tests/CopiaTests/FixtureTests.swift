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
