import Testing
import Foundation
import CopiaCore

private func item(_ pairs: (String, String)...) -> PasteboardItemData {
	PasteboardItemData(pairs.map { (type: $0.0, data: Data($0.1.utf8)) })
}

private func draft(_ items: PasteboardItemData..., at date: Date = .distantPast) -> ClipDraft {
	ClipDraft(items: items, copiedAt: date)
}

@Suite struct CaptureTests {
	@Test func classifiesEveryKind() {
		#expect(Capture.kind(of: draft(item((PasteboardTypes.string, "hello")))) == .text)
		#expect(Capture.kind(of: draft(item((PasteboardTypes.string, "hi"), (PasteboardTypes.rtf, "{\\rtf1 hi}")))) == .richText)
		#expect(Capture.kind(of: draft(item((PasteboardTypes.png, "PNGDATA")))) == .image)
		#expect(Capture.kind(of: draft(item((PasteboardTypes.string, "https://example.com/a")))) == .link)
		#expect(Capture.kind(of: draft(item((PasteboardTypes.fileURL, "file:///tmp/a.txt")))) == .file)
		#expect(Capture.kind(of: draft(item((PasteboardTypes.string, "#ff6a3d")))) == .color)
	}

	@Test func rtfOrHTMLWithoutAStringIsKeptWithItsText() {
		let rtf = draft(item((PasteboardTypes.rtf, "{\\rtf1\\ansi Quarterly \\b review\\b0}")))
		#expect(Capture.decide(types: [PasteboardTypes.rtf], draft: rtf, candidates: [], ignoredApps: []) == .keep)
		#expect(Capture.plainText(rtf) == "Quarterly review")
		#expect(Capture.kind(of: rtf) == .richText)
		let html = draft(item((PasteboardTypes.html, "<p>Ship <b>it</b> &amp; go</p>")))
		#expect(Capture.decide(types: [PasteboardTypes.html], draft: html, candidates: [], ignoredApps: []) == .keep)
		#expect(Capture.plainText(html) == "Ship it & go")
		let blank = draft(item((PasteboardTypes.rtf, "{\\rtf1\\ansi   }")))
		#expect(Capture.decide(types: [PasteboardTypes.rtf], draft: blank, candidates: [], ignoredApps: []) == .skipEmpty)
	}

	@Test func colorDetectionFollowsPasteRules() {
		#expect(Capture.colorHex("#1A2B3C") == "#1A2B3C")
		#expect(Capture.colorHex("1a2b3c") == "#1A2B3C")
		#expect(Capture.colorHex("235442") == nil)
		#expect(Capture.colorHex("#FFF") == nil)
		#expect(Capture.colorHex("rgb(1,2,3)") == nil)
		#expect(Capture.colorHex("color #1A2B3C here") == nil)
	}

	@Test func detectsCode() {
		#expect(Capture.looksLikeCode("func a() {\n    return 1\n}"))
		#expect(!Capture.looksLikeCode("Dear team,\nsee you Friday."))
	}

	@Test func skipsWhitespaceTooLargePrivateAndIgnoredApps() {
		let blank = draft(item((PasteboardTypes.string, "  \n\t ")))
		#expect(Capture.decide(types: [PasteboardTypes.string], draft: blank, candidates: [], ignoredApps: []) == .skipEmpty)
		let big = ClipDraft(items: [PasteboardItemData([(PasteboardTypes.png, Data(count: Capture.maxBytes + 1))])], copiedAt: .now)
		#expect(Capture.decide(types: [PasteboardTypes.png], draft: big, candidates: [], ignoredApps: []) == .skipTooLarge)
		let ok = draft(item((PasteboardTypes.string, "x")))
		for t in PasteboardTypes.ignored {
			#expect(Capture.decide(types: [PasteboardTypes.string, t], draft: ok, candidates: [], ignoredApps: []) == .skipPrivate)
		}
		#expect(Capture.decide(types: [PasteboardTypes.string], draft: ok, candidates: ["com.apple.Safari", "com.1password.1password"],
			ignoredApps: ["com.1password.1password"]) == .skipIgnoredApp)
		#expect(Capture.decide(types: [PasteboardTypes.string], draft: ok, candidates: ["com.apple.Safari"], ignoredApps: []) == .keep)
	}

	@Test func ownMarkerIsSkipped() {
		let ok = draft(item((PasteboardTypes.string, "x")))
		#expect(Capture.decide(types: [PasteboardTypes.string, PasteboardTypes.marker], draft: ok, candidates: [], ignoredApps: []) == .skipPrivate)
	}

	@Test func dedupKeyIncludesItemStructureAndIsOrderStableWithinAnItem() {
		let combined = draft(item((PasteboardTypes.string, "a"), (PasteboardTypes.html, "<b>a</b>")))
		let reordered = draft(item((PasteboardTypes.html, "<b>a</b>"), (PasteboardTypes.string, "a")))
		let split = draft(item((PasteboardTypes.string, "a")), item((PasteboardTypes.html, "<b>a</b>")))
		let differentRich = draft(item((PasteboardTypes.string, "a"), (PasteboardTypes.html, "<i>a</i>")))
		#expect(combined.contentKey == reordered.contentKey)
		#expect(combined.contentKey != split.contentKey)
		#expect(combined.contentKey != differentRich.contentKey)
		let twoFiles = draft(item((PasteboardTypes.fileURL, "file:///a")), item((PasteboardTypes.fileURL, "file:///b")))
		let swapped = draft(item((PasteboardTypes.fileURL, "file:///b")), item((PasteboardTypes.fileURL, "file:///a")))
		#expect(twoFiles.contentKey != swapped.contentKey)
		#expect(ClipDraft.uuid(forKey: combined.contentKey) == ClipDraft.uuid(forKey: reordered.contentKey))
	}

	@Test func activationLogFlagsEveryAppFrontmostSinceThePoll() {
		var log = ActivationLog(frontmost: "com.apple.TextEdit")
		log.activated("com.apple.Safari")
		let candidates = log.candidatesAndReset(currentFrontmost: "com.apple.Safari")
		#expect(candidates == ["com.apple.TextEdit", "com.apple.Safari"])
		#expect(Capture.decide(types: [PasteboardTypes.string], draft: draft(item((PasteboardTypes.string, "secret"))),
			candidates: candidates, ignoredApps: ["com.apple.TextEdit"]) == .skipIgnoredApp)
		#expect(ActivationLog.source(of: candidates, excluding: nil) == nil)
		#expect(ActivationLog.source(of: log.candidatesAndReset(currentFrontmost: "com.apple.Safari"), excluding: nil) == "com.apple.Safari")
	}

	@Test func retentionCutoffs() {
		let now = Date(timeIntervalSince1970: 1_800_000_000)
		#expect(Retention.forever.cutoff(now: now) == nil)
		#expect(Retention.day.cutoff(now: now)! < now)
		#expect(Retention.month.cutoff(now: now)! < Retention.week.cutoff(now: now)!)
		#expect(Retention.allCases.map(\.title) == ["1 Day", "1 Week", "1 Month", "1 Year", "Forever"])
	}
}
