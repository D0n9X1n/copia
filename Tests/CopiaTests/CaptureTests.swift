import Testing
import Foundation
import CopiaCore

private func item(_ pairs: (String, String)...) -> PasteboardItemData {
	PasteboardItemData(pairs.map { (type: $0.0, data: Data($0.1.utf8)) })
}

private func draft(_ items: PasteboardItemData..., at date: Date = .distantPast) -> ClipDraft {
	ClipDraft(items: items, copiedAt: date)
}

/// A monotonic timestamp for ActivationLog, in seconds.
private func t(_ seconds: TimeInterval) -> TimeInterval { 1_000 + seconds }

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

	/// A bare `public.url` item is a link whose text is its URL; a file's URL never replaces its path.
	@Test func aURLOnlyItemIsALinkWithItsURLAsText() {
		let bare = draft(item((PasteboardTypes.url, "https://example.com")))
		#expect(Capture.plainText(bare) == "https://example.com")
		#expect(Capture.kind(of: bare) == .link)
		let file = draft(item((PasteboardTypes.fileURL, "file:///tmp/a.txt"), (PasteboardTypes.url, "file:///tmp/a.txt")))
		#expect(Capture.plainText(file) == "")
		#expect(Capture.kind(of: file) == .file)
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

	@Test func activationLogFlagsEveryAppFrontmostInTheWindow() {
		var log = ActivationLog(frontmost: "com.apple.TextEdit", at: t(0))
		log.activated("com.apple.Safari", at: t(0.2))
		log.activated("com.apple.Notes", at: t(0.3))
		let candidates = log.candidates(until: t(0.5), currentFrontmost: "com.apple.Notes")
		#expect(candidates == ["com.apple.TextEdit", "com.apple.Safari", "com.apple.Notes"])
		#expect(Capture.decide(types: [PasteboardTypes.string], draft: draft(item((PasteboardTypes.string, "secret"))),
			candidates: candidates, ignoredApps: ["com.apple.TextEdit"]) == .skipIgnoredApp)
		#expect(ActivationLog.source(of: candidates, excluding: nil) == nil)
		// The next window holds only the app that stayed in front, so it is the sole candidate and the source.
		let next = log.candidates(until: t(1.0), currentFrontmost: "com.apple.Notes")
		#expect(next == ["com.apple.Notes"])
		#expect(ActivationLog.source(of: next, excluding: nil) == "com.apple.Notes")
	}

	/// The window is set by time, not by when the activation reached the log.
	@Test func activationsAreAssignedToTheirWindowByTimestamp() {
		// Stamped after this poll: it belongs to the next window, not this one.
		var early = ActivationLog(frontmost: "com.apple.TextEdit", at: t(0))
		early.activated("com.1password.1password", at: t(0.7))
		#expect(early.candidates(until: t(0.5), currentFrontmost: "com.apple.TextEdit") == ["com.apple.TextEdit"])
		#expect(early.candidates(until: t(1.0), currentFrontmost: "com.apple.TextEdit") == ["com.apple.TextEdit", "com.1password.1password"])

		// Logged after the 0.5 poll but stamped 0.4: that app was in front when the window opened, and the app
		// it replaced at 0.4 was not frontmost at any time in (0.5, 1.0].
		var late = ActivationLog(frontmost: "com.apple.TextEdit", at: t(0))
		late.roll(at: t(0.5))
		late.activated("com.1password.1password", at: t(0.4))
		#expect(late.candidates(until: t(1.0), currentFrontmost: "com.apple.Safari") == ["com.1password.1password", "com.apple.Safari"])
	}

	/// The app frontmost at poll time is always a candidate, whatever the stamps say: an ignored app in front always skips.
	@Test func theFrontmostAppAtPollTimeIsAlwaysACandidate() {
		// The reviewer's sequence: an editor at 100, the ignored app stamped 99.8, a poll at 99.9 with it still in front.
		var stepped = ActivationLog(frontmost: "com.apple.TextEdit", at: t(100))
		stepped.activated("com.1password.1password", at: t(99.8))
		let candidates = stepped.candidates(until: t(99.9), currentFrontmost: "com.1password.1password")
		#expect(candidates.contains("com.1password.1password"))
		#expect(Capture.decide(types: [PasteboardTypes.string], draft: draft(item((PasteboardTypes.string, "secret"))),
			candidates: candidates, ignoredApps: ["com.1password.1password"]) == .skipIgnoredApp)
		// Its activation was never logged at all.
		var missed = ActivationLog(frontmost: "com.apple.TextEdit", at: t(0))
		#expect(missed.candidates(until: t(0.5), currentFrontmost: "com.1password.1password").contains("com.1password.1password"))
	}

	@Test func aWindowClosedWithoutACopyDropsTheAppsItSaw() {
		var log = ActivationLog(frontmost: "com.apple.TextEdit", at: t(0))
		log.activated("com.1password.1password", at: t(0.2))
		log.activated("com.apple.TextEdit", at: t(0.3))
		log.roll(at: t(0.5))
		#expect(log.candidates(until: t(1.0), currentFrontmost: "com.apple.TextEdit") == ["com.apple.TextEdit"])
	}

	@Test func retentionCutoffs() {
		let now = Date(timeIntervalSince1970: 1_800_000_000)
		#expect(Retention.forever.cutoff(now: now) == nil)
		#expect(Retention.day.cutoff(now: now)! < now)
		#expect(Retention.month.cutoff(now: now)! < Retention.week.cutoff(now: now)!)
		#expect(Retention.allCases.map(\.title) == ["1 Day", "1 Week", "1 Month", "1 Year", "Forever"])
	}
}
