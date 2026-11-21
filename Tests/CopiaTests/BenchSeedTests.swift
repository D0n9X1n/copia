import Testing
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
}
