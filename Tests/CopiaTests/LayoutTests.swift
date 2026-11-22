import Testing
import AppKit
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

@Suite struct LayoutTests {
	@Test func stripSitsEightPointsInsideTheVisibleFrame() {
		let visible = CGRect(x: -1224, y: 80, width: 1224, height: 2176)
		#expect(PanelLayout.stripFrame(in: visible) == CGRect(x: -1216, y: 88, width: 1208, height: 316))
		let window = PanelLayout.windowFrame(in: visible)
		#expect(window.contains(PanelLayout.stripFrame(in: visible)))
		#expect(window.minY == 88)
	}

	@Test(arguments: [0, 4, 8, 39])
	func selectedCardKeepsA24PointMargin(index: Int) {
		let viewport: CGFloat = 900
		let content = PanelLayout.contentWidth(count: 40)
		let minX = PanelLayout.cardMinX(index: index)
		for current in stride(from: 0.0, through: Double(content - viewport), by: 250) {
			let offset = PanelLayout.offset(selectedMinX: minX, viewport: viewport, current: current, contentWidth: content)
			let left = minX - offset
			let right = offset + viewport - (minX + Theme.cardSize.width)
			#expect(left >= 24 - 0.001 || offset == 0)
			#expect(right >= 24 - 0.001 || offset == content - viewport)
			#expect(offset >= 0 && offset <= content - viewport)
		}
	}

	@Test func offsetDoesNotMoveWhenTheCardIsAlreadyVisible() {
		let content = PanelLayout.contentWidth(count: 20)
		#expect(PanelLayout.offset(selectedMinX: PanelLayout.cardMinX(index: 2), viewport: 1200, current: 0, contentWidth: content) == 0)
	}
}

@MainActor
@Suite struct CardTests {
	@Test func anatomyMatchesTheBrief() {
		let p = CardPresentation(clip: Fixtures.mixed[0])
		#expect(p.size == CGSize(width: 216, height: 232))
		#expect(p.headerHeight + p.bodyHeight + p.footerHeight == 232)
	}

	@Test func truncationIsTailForTextAndMiddleForFileNames() {
		let p = CardPresentation(clip: Fixtures.mixed[6])
		#expect(p.textTruncation == .tail)
		#expect(p.fileNameTruncation == .middle)
	}

	@Test func codeShowsNineLinesAndProseEight() {
		#expect(CardPresentation(clip: Fixtures.mixed[1]).lineLimit == 9)
		#expect(CardPresentation(clip: Fixtures.mixed[0]).lineLimit == 8)
	}

	@Test func pendingAndFailedPreviewsAreNeverBlank() {
		#expect(CardPresentation(clip: Fixtures.pending).placeholderOpacity == 0.30)
		#expect(CardPresentation(clip: Fixtures.failed).fallback == "https://offline.example.org/article")
	}

	@Test func voiceOverReadsOneLabelWithFourActions() {
		let clip = Fixtures.extremes[1]
		let a = CardAccessibility(clip: clip, now: Fixtures.now)
		#expect(a.actions == ["Paste", "Paste as Plain Text", "Copy", "Delete"])
		#expect(a.preview.count == 120)
		#expect(a.label.hasPrefix("Text from TextEdit, just now: Lorem"))
		#expect(CardAccessibility(clip: Fixtures.extremes[11], now: Fixtures.now).label.contains("Unknown app"))
	}

	@Test func thumbnailCacheDecodesOnceAtDisplaySizeAndEmpties() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-thumb-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let assets = try FixtureAssets.prepare(in: dir)
		guard case let .ready(url) = assets.mixed[3].preview else { Issue.record("no preview"); return }
		let cache = ThumbnailCache()
		let image = try #require(cache.image(at: url))
		#expect(max(image.size.width, image.size.height) <= 384)
		_ = cache.image(at: url)
		#expect(cache.decodeCount == 1)
		#expect(cache.entryCount == 1)
		cache.removeAll()
		#expect(cache.entryCount == 0)
	}
}

@MainActor
@Suite struct CardContentTests {
	let saved = URL(fileURLWithPath: "/tmp/copia-saved-preview.png")

	@Test func aFileCardShowsItsSavedThumbnailAt96Points() {
		var clip = Fixtures.mixed[6]
		clip.preview = .ready(saved)
		let p = CardPresentation(clip: clip)
		#expect(p.bodyKind == .file)
		#expect(p.fileThumbnail == saved)
		#expect(p.previewURL == saved)
		#expect(p.fileThumbnailSide == 96)
		#expect(CardPresentation(clip: Fixtures.mixed[6]).fileThumbnail == nil)
	}

	@Test func multipleFilesStackUpToThreeWithACount() {
		let many = CardPresentation(clip: Fixtures.extremes[8])
		#expect(many.fileStack == 3)
		#expect(many.fileCount == "+299")
		let one = CardPresentation(clip: Fixtures.mixed[6])
		#expect(one.fileStack == 1)
		#expect(one.fileCount == nil)
	}

	@Test func aLinkWithASavedSiteIconShowsA32PointFaviconAndTwoTitleLines() {
		var clip = Fixtures.mixed[2]
		clip.preview = .icon(saved)
		let p = CardPresentation(clip: clip)
		#expect(p.linkArt == .favicon(saved))
		#expect(p.previewURL == saved)
		#expect(p.faviconSide == 32)
		#expect(p.title == "Paste in Liquid Glass")
		#expect(p.titleLines == 2)
	}

	@Test func aFailedLinkKeepsItsTitleWithALinkGlyph() {
		var clip = Fixtures.mixed[2]
		clip.preview = .failed
		let p = CardPresentation(clip: clip)
		#expect(p.linkArt == .glyph)
		#expect(p.symbol == "link")
		#expect(p.title == "Paste in Liquid Glass")
		#expect(p.fallback == "Paste in Liquid Glass")
	}

	@Test func rightToLeftTextUsesNaturalAlignment() {
		#expect(CardPresentation(clip: Fixtures.extremes[3]).textDirection == .rightToLeft)
		#expect(CardPresentation(clip: Fixtures.extremes[4]).textDirection == .leftToRight)
		#expect(CardPresentation(clip: Fixtures.mixed[0]).textDirection == .leftToRight)
		// The first strong character decides, as natural alignment does.
		#expect(CardPresentation.direction(of: "123 שלום world") == .rightToLeft)
		#expect(CardPresentation.direction(of: "“Hello” مرحبا") == .leftToRight)
	}

	@Test func richTextStaysPlainTextWithItsRTFMeta() {
		let p = CardPresentation(clip: Fixtures.mixed[5])
		#expect(p.bodyKind == .prose)
		#expect(p.footer == "112 chars · RTF")
	}
}
