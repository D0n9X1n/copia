import Testing
import Foundation

/// The app icon's source layers, as the brief describes them.
@Suite struct IconTests {
	static let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		.appendingPathComponent("Resources/AppIcon.icon/Assets")

	/// The front card's header is persimmon at 18%, not an opaque band.
	@Test func theFrontCardHeaderIsAnEighteenPercentPersimmonBand() throws {
		let svg = try String(contentsOf: Self.assets.appendingPathComponent("card-front-details.svg"), encoding: .utf8)
		let rects = svg.matches(of: /<rect\b[^>]*>/).map { String($0.output) }
		let header = try #require(rects.first { $0.contains("fill=\"#FF6A3D\"") }, "no persimmon rect in \(rects)")
		#expect(header.contains("height=\"104\""))
		#expect(header.contains("fill-opacity=\"0.18\""), "\(header)")
	}
}
