import Foundation
import CopiaCore

/// Deterministic sample clips for the render harness, tests and the fixture-backed app.
public enum Fixtures {
	/// Fixed reference time so relative timestamps render the same on every run.
	public static let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

	static func id(_ family: UInt8, _ index: Int) -> UUID {
		let i = UInt32(index)
		return UUID(uuid: (family, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			UInt8(i >> 24 & 0xFF), UInt8(i >> 16 & 0xFF), UInt8(i >> 8 & 0xFF), UInt8(i & 0xFF)))
	}

	static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

	/// Nine cards: every kind, plus a code snippet.
	public static let mixed: [Clip] = [
		Clip(id: id(1, 0), kind: .text,
			text: "Ship the release notes by Friday — include the new keyboard shortcuts and the performance numbers from the bench run.",
			sourceName: "Notes", sourceBundleID: "com.apple.Notes", timestamp: ago(40), meta: "118 chars"),
		Clip(id: id(1, 1), kind: .text,
			text: "func move(_ delta: Int) {\n    guard !visible.isEmpty else { return }\n    let i = visible.firstIndex { $0.id == selectedID } ?? 0\n    select(visible[min(max(i + delta, 0), visible.count - 1)].id)\n}",
			isCode: true, sourceName: "Xcode", sourceBundleID: "com.apple.dt.Xcode", timestamp: ago(130), meta: "176 chars"),
		Clip(id: id(1, 2), kind: .link, text: "Paste in Liquid Glass",
			sourceName: "Safari", sourceBundleID: "com.apple.Safari", timestamp: ago(300), meta: "pasteapp.io",
			url: URL(string: "https://pasteapp.io/blog/paste-in-liquid-glass")),
		Clip(id: id(1, 3), kind: .image, text: "Screenshot 2026-11-20 at 16.48.png",
			sourceName: "Preview", sourceBundleID: "com.apple.Preview", timestamp: ago(900), meta: "2400×1600 · PNG"),
		Clip(id: id(1, 4), kind: .color, text: "#FF6A3D",
			sourceName: "Digital Color Meter", sourceBundleID: "com.apple.DigitalColorMeter", timestamp: ago(1_800), meta: "Hex color", colorHex: "#FF6A3D"),
		Clip(id: id(1, 5), kind: .richText,
			text: "Quarterly review: revenue up 18%, churn down to 2.1%, and the new onboarding flow lifted activation by a third.",
			sourceName: "TextEdit", sourceBundleID: "com.apple.TextEdit", timestamp: ago(3_600), meta: "112 chars · RTF"),
		Clip(id: id(1, 6), kind: .file, text: "Design Review.key",
			sourceName: "Finder", sourceBundleID: "com.apple.finder", timestamp: ago(7_200), meta: "1 file · 4.2 MB",
			fileNames: ["Design Review.key"]),
		Clip(id: id(1, 7), kind: .text, text: "hello@example.com",
			sourceName: "Mail", sourceBundleID: "com.apple.mail", timestamp: ago(86_400), meta: "17 chars"),
		Clip(id: id(1, 8), kind: .file, text: "3 files",
			sourceName: "Finder", sourceBundleID: "com.apple.finder", timestamp: ago(172_800), meta: "3 files · 18.6 MB",
			fileNames: ["Budget 2027.numbers", "Roadmap.pdf", "Team photo.heic"]),
	]

	/// Edge cases from the design brief's extremes list.
	public static let extremes: [Clip] = [
		Clip(id: id(2, 0), kind: .text, text: "A", sourceName: "TextEdit", sourceBundleID: "com.apple.TextEdit",
			timestamp: ago(5), meta: "1 char"),
		Clip(id: id(2, 1), kind: .text, text: String(String(repeating: "Lorem ipsum dolor sit amet. ", count: 1_786).prefix(50_000)),
			sourceName: "TextEdit", sourceBundleID: "com.apple.TextEdit", timestamp: ago(10), meta: "50,000 chars"),
		Clip(id: id(2, 2), kind: .link,
			text: "https://example.com/a/very/long/unbreakable/path/segment/that/keeps/going/without/any/spaces/at/all/0123456789abcdef",
			sourceName: "Safari", sourceBundleID: "com.apple.Safari", timestamp: ago(20), meta: "example.com", preview: .failed,
			url: URL(string: "https://example.com/a/very/long/unbreakable/path/segment/that/keeps/going/without/any/spaces/at/all/0123456789abcdef")),
		Clip(id: id(2, 3), kind: .text, text: "مرحبا بالعالم — هذا نص من اليمين إلى اليسار",
			sourceName: "Notes", sourceBundleID: "com.apple.Notes", timestamp: ago(30), meta: "43 chars"),
		Clip(id: id(2, 4), kind: .text, text: "剪贴板历史记录让你随时找回复制过的内容。快捷键 ⌘Y 打开。",
			sourceName: "Notes", sourceBundleID: "com.apple.Notes", timestamp: ago(40), meta: "30 chars"),
		Clip(id: id(2, 5), kind: .text, text: "👩‍💻👨‍👩‍👧‍👦🏳️‍🌈 family + dev + flag",
			sourceName: "Messages", sourceBundleID: "com.apple.MobileSMS", timestamp: ago(50), meta: "24 chars"),
		Clip(id: id(2, 6), kind: .image, text: "Panorama.tiff", sourceName: "Photos", sourceBundleID: "com.apple.Photos",
			timestamp: ago(60), meta: "8000×8000 · TIFF"),
		Clip(id: id(2, 7), kind: .image, text: "Logo.png", sourceName: "Preview", sourceBundleID: "com.apple.Preview",
			timestamp: ago(70), meta: "512×512 · PNG · transparent"),
		Clip(id: id(2, 8), kind: .file, text: "300 files", sourceName: "Finder", sourceBundleID: "com.apple.finder",
			timestamp: ago(80), meta: "300 files · 1.2 GB",
			fileNames: (1...300).map { "IMG_\(String(format: "%04d", $0)).heic" }),
		Clip(id: id(2, 9), kind: .color, text: "#FFFFFF", sourceName: "Figma", sourceBundleID: "com.figma.Desktop",
			timestamp: ago(90), meta: "Hex color", colorHex: "#FFFFFF"),
		Clip(id: id(2, 10), kind: .color, text: "#000000", sourceName: "Figma", sourceBundleID: "com.figma.Desktop",
			timestamp: ago(100), meta: "Hex color", colorHex: "#000000"),
		Clip(id: id(2, 11), kind: .text, text: "Copied from an app Copia could not identify.",
			sourceName: nil, sourceBundleID: nil, timestamp: ago(110), meta: "44 chars"),
		Clip(id: id(2, 12), kind: .file,
			text: "An extremely long document name that keeps going well past the card width - final - v12 (edited).pdf",
			sourceName: "Finder", sourceBundleID: "com.apple.finder", timestamp: ago(120), meta: "1 file · 2.1 MB",
			fileNames: ["An extremely long document name that keeps going well past the card width - final - v12 (edited).pdf"]),
	]

	/// A link whose preview fetch failed.
	public static let failed = Clip(id: id(3, 0), kind: .link, text: "https://offline.example.org/article",
		sourceName: "Safari", sourceBundleID: "com.apple.Safari", timestamp: ago(15), meta: "offline.example.org",
		preview: .failed, url: URL(string: "https://offline.example.org/article"))

	/// An image whose preview is still being generated.
	public static let pending = Clip(id: id(3, 1), kind: .image, text: "Whiteboard.jpg",
		sourceName: "Photos", sourceBundleID: "com.apple.Photos", timestamp: ago(25), meta: "4032×3024 · JPEG",
		preview: .pending)

	/// Ten thousand distinct text clips for lazy-row and scroll tests.
	public static let tenThousand: [Clip] = (0..<10_000).map { i in
		Clip(id: id(4, i), kind: .text, text: "History item \(i + 1)", sourceName: "Notes",
			sourceBundleID: "com.apple.Notes", timestamp: ago(TimeInterval(i * 60)), meta: "\(14 + String(i + 1).count) chars")
	}
}
