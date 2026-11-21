import Testing
import AppKit
import Synchronization
import CopiaCore
@testable import CopiaStore
@testable import CopiaSystem
import CopiaUI

@MainActor
final class FakePasteboard: PasteboardSource {
	var changeCount = 0
	var typeIdentifiers: Set<String> = []
	var items: [PasteboardItemData] = []
	var reads = 0
	/// Runs inside `readItems`, so a test can change the pasteboard mid-read.
	var onRead: () -> Void = {}
	func readItems() -> [PasteboardItemData] { reads += 1; onRead(); return items }
	func copy(_ text: String, extraTypes: Set<String> = []) {
		changeCount += 1
		items = [PasteboardItemData([(PasteboardTypes.string, Data(text.utf8))])]
		typeIdentifiers = Set([PasteboardTypes.string]).union(extraTypes)
	}
}

@MainActor
@Suite struct WatcherTests {
	func make(_ pb: FakePasteboard, front: @escaping () -> String? = { "com.apple.TextEdit" }) -> (PasteboardWatcher, () -> [ClipDraft]) {
		var drafts: [ClipDraft] = []
		let w = PasteboardWatcher(source: pb, ignoredApps: ["com.1password.1password"], frontmost: front, appName: { _ in "App" })
		w.onDraft = { drafts.append($0) }
		return (w, { drafts })
	}

	@Test func emitsOneDraftPerObservedChange() {
		let pb = FakePasteboard()
		let (w, drafts) = make(pb)
		pb.copy("hello")
		w.tick(); w.tick()
		#expect(drafts().count == 1)
		#expect(drafts().first?.sourceBundleID == "com.apple.TextEdit")
	}

	@Test func concealedContentIsNeverRead() {
		let pb = FakePasteboard()
		let (w, drafts) = make(pb)
		pb.copy("secret", extraTypes: ["org.nspasteboard.ConcealedType"])
		w.tick()
		#expect(drafts().isEmpty)
		#expect(pb.reads == 0)
	}

	@Test func copyInIgnoredAppThenSwitchingIsStillSkipped() {
		let pb = FakePasteboard()
		var front = "com.1password.1password"
		let (w, drafts) = make(pb, front: { front })
		w.tick()
		pb.copy("password")
		front = "com.apple.Safari"
		w.appActivated("com.apple.Safari")
		w.tick()
		#expect(drafts().isEmpty)
		#expect(w.lastDecision == .skipIgnoredApp)
	}

	@Test func ignoredAppEditsChangeCapture() {
		let pb = FakePasteboard()
		let (w, drafts) = make(pb)
		w.ignoredApps = ["com.apple.TextEdit"]
		pb.copy("a"); w.tick()
		#expect(drafts().isEmpty)
		w.ignoredApps = []
		pb.copy("b"); w.tick()
		#expect(drafts().count == 1)
	}

	@Test func copiesMadeWhilePausedAreNeverCaptured() {
		let pb = FakePasteboard()
		let (w, drafts) = make(pb)
		w.setPaused(true)
		pb.copy("while paused"); w.tick()
		w.setPaused(false)
		w.tick()
		#expect(drafts().isEmpty)
		pb.copy("after"); w.tick()
		#expect(drafts().count == 1)
	}

	@Test func aCopyThatLandsDuringTheReadIsNotStoredUnderTheOldTypes() {
		let pb = FakePasteboard()
		let (w, drafts) = make(pb)
		pb.copy("plain")
		pb.onRead = { pb.onRead = {}; pb.copy("secret", extraTypes: ["org.nspasteboard.ConcealedType"]) }
		w.tick()
		#expect(drafts().isEmpty)
		w.tick()
		#expect(drafts().isEmpty)
		#expect(w.lastDecision == .skipPrivate)
	}

	@Test func anIgnoredAppVisitedEarlierDoesNotBlockALaterCopy() {
		let pb = FakePasteboard()
		var front = "com.apple.TextEdit"
		let (w, drafts) = make(pb, front: { front })
		front = "com.1password.1password"
		w.appActivated(front)
		w.tick()
		front = "com.apple.TextEdit"
		w.appActivated(front)
		w.tick(); w.tick()
		pb.copy("hello"); w.tick()
		#expect(drafts().count == 1)
		#expect(drafts().first?.sourceBundleID == "com.apple.TextEdit")
	}

	/// The reviewer's sequence: the wall clock steps back while an ignored app comes to the front and stays there.
	@Test func anIgnoredAppInFrontIsSkippedWhenTheWallClockStepsBack() {
		let pb = FakePasteboard()
		var wall = Date(timeIntervalSince1970: 100)
		var front = "com.apple.TextEdit"
		var drafts: [ClipDraft] = []
		let w = PasteboardWatcher(source: pb, ignoredApps: ["com.1password.1password"], now: { wall }, frontmost: { front },
			appName: { _ in "App" })
		w.onDraft = { drafts.append($0) }
		wall = Date(timeIntervalSince1970: 99.8)
		front = "com.1password.1password"
		w.appActivated(front)
		pb.copy("secret")
		wall = Date(timeIntervalSince1970: 99.9)
		w.tick()
		#expect(drafts.isEmpty)
		#expect(w.lastDecision == .skipIgnoredApp)
	}

	/// Activation windows run on a monotonic clock: an ignored app in front only between polls still skips the copy
	/// when the wall clock steps back.
	@Test func activationWindowsIgnoreAWallClockThatStepsBack() {
		let pb = FakePasteboard()
		var wall = Date(timeIntervalSince1970: 100)
		var uptime: TimeInterval = 1
		var front = "com.apple.TextEdit"
		var drafts: [ClipDraft] = []
		let w = PasteboardWatcher(source: pb, ignoredApps: ["com.1password.1password"], now: { wall }, uptime: { uptime },
			frontmost: { front }, appName: { _ in "App" })
		w.onDraft = { drafts.append($0) }
		wall = Date(timeIntervalSince1970: 99.8); uptime = 2
		front = "com.1password.1password"; w.appActivated(front)
		pb.copy("secret")
		uptime = 3
		front = "com.apple.TextEdit"; w.appActivated(front)
		wall = Date(timeIntervalSince1970: 99.9); uptime = 4
		w.tick()
		#expect(drafts.isEmpty)
		#expect(w.lastDecision == .skipIgnoredApp)
	}

	/// Rich text captured from the pasteboard shows its plain text with an "RTF" footer (Amendment 5).
	@Test func capturedRichTextIsSavedWithAnRTFFooter() async throws {
		let pb = FakePasteboard()
		let (w, drafts) = make(pb)
		pb.changeCount += 1
		pb.items = [PasteboardItemData([(PasteboardTypes.rtf, Data("{\\rtf1\\ansi Quarterly \\b review\\b0}".utf8))])]
		pb.typeIdentifiers = [PasteboardTypes.rtf]
		w.tick()
		let draft = try #require(drafts().first)
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-rtf-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let (clip, _) = try await ClipStore(directory: dir).insert(draft)
		#expect(clip.kind == .richText)
		#expect(clip.title == "Quarterly review")
		#expect(clip.meta == "16 chars · RTF")
	}
}

@MainActor
@Suite struct PasterTests {
	let items = [PasteboardItemData([(PasteboardTypes.string, Data("hi".utf8)), (PasteboardTypes.html, Data("<b>hi</b>".utf8))])]

	func pasteboard() -> NSPasteboard { NSPasteboard(name: .init("copia-test-\(UUID().uuidString)")) }

	@Test func writesMarkerSoCaptureSkipsIt() {
		let pb = pasteboard()
		Paster(pasteboard: pb).write(items, plain: false)
		let types = Set((pb.types ?? []).map(\.rawValue))
		#expect(types.contains(PasteboardTypes.marker))
		#expect(types.contains(PasteboardTypes.html))
		#expect(!types.isDisjoint(with: PasteboardTypes.ignored))
	}

	@Test func plainTextKeepsOnlyTheString() {
		let pb = pasteboard()
		Paster(pasteboard: pb).write(items, plain: true)
		let types = Set((pb.types ?? []).map(\.rawValue))
		#expect(types.contains(PasteboardTypes.string))
		#expect(!types.contains(PasteboardTypes.html))
	}

	@Test func plainTextOfFilesIsTheirPaths() {
		let pb = pasteboard()
		let files = [PasteboardItemData([(PasteboardTypes.fileURL, Data("file:///tmp/Design%20Review.key".utf8))]),
			PasteboardItemData([(PasteboardTypes.fileURL, Data("file:///tmp/b.txt".utf8))])]
		Paster(pasteboard: pb).write(files, plain: true)
		let types = Set((pb.types ?? []).map(\.rawValue))
		#expect(!types.contains(PasteboardTypes.fileURL))
		#expect(pb.pasteboardItems?.compactMap { $0.string(forType: .string) } == ["/tmp/Design Review.key", "/tmp/b.txt"])
	}

	@Test func plainTextOfRichTextWithoutAStringIsItsText() {
		let pb = pasteboard()
		Paster(pasteboard: pb).write([PasteboardItemData([(PasteboardTypes.html, Data("<p>Ship <b>it</b></p>".utf8))])], plain: true)
		#expect(pb.string(forType: .string) == "Ship it")
		#expect(!Set((pb.types ?? []).map(\.rawValue)).contains(PasteboardTypes.html))
	}

	@Test func pasteClosesBeforeSendingAndReportsPasted() async {
		var log: [String] = []
		let paster = Paster(pasteboard: pasteboard(), isTrusted: { true }, postPaste: { log.append("cmdV") },
			waitForFront: { _ in log.append("front"); return true })
		let result = await paster.paste(items, plain: false, target: NSRunningApplication.current) { log.append("close") }
		#expect(result == .pasted)
		#expect(log == ["close", "front", "cmdV"])
	}

	@Test func withoutAccessibilityItOnlyCopies() async {
		var sent = false
		var closed = false
		let pb = pasteboard()
		let paster = Paster(pasteboard: pb, isTrusted: { false }, postPaste: { sent = true }, waitForFront: { _ in true })
		let result = await paster.paste(items, plain: false, target: nil) { closed = true }
		#expect(result == .accessibilityRequired)
		#expect(!sent && !closed)
		#expect(pb.string(forType: .string) == "hi")
	}

	@Test func aTargetThatLosesFrontDuringTheSettleDelayIsNotPastedInto() async {
		var front: pid_t = 1
		let ok = await Paster.activateAndWait(pid: 1, frontmost: { front }, activate: {},
			sleep: { ms in if ms == Paster.settleMilliseconds { front = 2 } })
		#expect(!ok)
	}

	@Test func aTargetThatStaysFrontIsPastedInto() async {
		var slept: [Int] = []
		let ok = await Paster.activateAndWait(pid: 1, frontmost: { 1 }, activate: {}, sleep: { slept.append($0) })
		#expect(ok)
		#expect(slept == [Paster.settleMilliseconds])
	}

	/// The whole wait, settle included, stays within 300 ms: a target first seen at 290 ms has no room left to settle.
	@Test func theWaitIncludingTheSettleNeverPasses300Milliseconds() async {
		var slept: [Int] = []
		var polls = 0
		var clock = ContinuousClock.now
		let late = await Paster.activateAndWait(pid: 1, frontmost: { polls >= 29 ? 1 : 2 }, activate: {},
			sleep: { ms in slept.append(ms); clock = clock.advanced(by: .milliseconds(ms)); if ms == 10 { polls += 1 } },
			now: { clock })
		#expect(slept.reduce(0, +) <= 300)
		#expect(!late)

		slept = []; polls = 0
		let justInTime = await Paster.activateAndWait(pid: 1, frontmost: { polls >= 27 ? 1 : 2 }, activate: {},
			sleep: { ms in slept.append(ms); clock = clock.advanced(by: .milliseconds(ms)); if ms == 10 { polls += 1 } },
			now: { clock })
		#expect(justInTime)
		#expect(slept.reduce(0, +) == 300)
		#expect(slept.last == Paster.settleMilliseconds)
	}

	/// The budget is elapsed time on a monotonic clock, not the sum of requested sleeps: here every sleep takes three
	/// times what it asked for, as under scheduling delay (B2:14).
	@Test func theBudgetIsElapsedTimeNotRequestedSleeps() async {
		let start = ContinuousClock.now
		var clock = start
		var polls = 0
		func wait(frontAfter: Int) async -> Bool {
			clock = start; polls = 0
			return await Paster.activateAndWait(pid: 1, frontmost: { polls >= frontAfter ? 1 : 2 }, activate: {},
				sleep: { ms in clock = clock.advanced(by: .milliseconds(3 * ms)); if ms == 10 { polls += 1 } },
				now: { clock })
		}
		// Never comes forward: polling stops within the budget, not after 280 ms of requested sleeps (840 ms elapsed).
		#expect(await wait(frontAfter: .max) == false)
		#expect(clock - start <= .milliseconds(300))
		// Seen at 240 ms elapsed: the settle ends at 330 ms, past the budget, so it is not pasted into.
		#expect(await wait(frontAfter: 8) == false)
		// Seen early: pasted into, with the settle inside the budget.
		#expect(await wait(frontAfter: 2) == true)
		#expect(clock - start <= .milliseconds(300))
	}

	/// Every stored item and representation reaches the pasteboard in order, read back through spy events.
	@Test func pasteWritesEveryItemAndRepresentationInOrder() async throws {
		let pb = pasteboard()
		defer { pb.releaseGlobally() }
		var events: [String] = []
		let paster = Paster(pasteboard: pb, isTrusted: { true }, postPaste: { events.append("cmdV") },
			waitForFront: { _ in events.append("front"); return true })
		let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
		let mixed = PasteboardItemData([(PasteboardTypes.string, Data("hi".utf8)), (PasteboardTypes.rtf, Data("{\\rtf1 hi}".utf8)),
			(PasteboardTypes.html, Data("<b>hi</b>".utf8)), (PasteboardTypes.png, png)])
		let files = ["c.txt", "a.txt", "b.txt"].map { PasteboardItemData([(PasteboardTypes.fileURL, Data("file:///tmp/\($0)".utf8))]) }
		let items = [mixed] + files

		func readBack() -> [PasteboardItemData] {
			(pb.pasteboardItems ?? []).map { item in
				// As Copia reads a pasteboard: stored types only. The server adds translations such as UTF-16 text on read.
				PasteboardItemData(item.types.map(\.rawValue)
					.filter { PasteboardTypes.stored.contains($0) }
					.map { (type: $0, data: item.data(forType: NSPasteboard.PasteboardType($0)) ?? Data()) })
			}
		}

		let result = await paster.paste(items, plain: false, target: NSRunningApplication.current) { events.append("close") }
		#expect(result == .pasted)
		#expect(events == ["close", "front", "cmdV"])
		let back = readBack()
		#expect(back.count == items.count)
		for (got, sent) in zip(back, items) {
			#expect(Set(got.representations.map(\.type)) == Set(sent.representations.map(\.type)))
			for rep in sent.representations { #expect(got.data(for: rep.type) == rep.data, "\(rep.type)") }
		}
		#expect(back.compactMap { $0.data(for: PasteboardTypes.fileURL) } == files.compactMap { $0.data(for: PasteboardTypes.fileURL) })
		for item in pb.pasteboardItems ?? [] {
			#expect(item.types.map(\.rawValue).contains(PasteboardTypes.marker))
		}

		events = []
		#expect(await paster.paste(items, plain: true, target: NSRunningApplication.current) {} == .pasted)
		#expect(readBack() == [PasteboardItemData([(PasteboardTypes.string, Data("hi".utf8))])]
			+ ["/tmp/c.txt", "/tmp/a.txt", "/tmp/b.txt"].map { PasteboardItemData([(PasteboardTypes.string, Data($0.utf8))]) })
		#expect(events == ["front", "cmdV"])
	}

	@Test func aTargetThatNeverComesForwardIsNotPastedInto() async {
		var sent = false
		let paster = Paster(pasteboard: pasteboard(), isTrusted: { true }, postPaste: { sent = true }, waitForFront: { _ in false })
		let result = await paster.paste(items, plain: false, target: NSRunningApplication.current) {}
		#expect(result == .copied)
		#expect(!sent)
	}
}

/// Counts fetches so "fetched once" is provable.
final class CountingLinks: LinkFetching, @unchecked Sendable {
	var calls = 0
	var urls: [URL] = []
	var result: Result<LinkPreview, Error> = .success(LinkPreview(title: "A title"))
	func fetch(_ url: URL) async throws -> LinkPreview {
		calls += 1
		urls.append(url)
		return try result.get()
	}
}

/// Holds the first fetch until released, so a test can delete and restore while it is in flight.
final class GatedLinks: LinkFetching, Sendable {
	private let state = Mutex<(calls: Int, gate: CheckedContinuation<Void, Never>?)>((0, nil))
	var calls: Int { state.withLock { $0.calls } }
	func fetch(_ url: URL) async throws -> LinkPreview {
		let call = state.withLock { $0.calls += 1; return $0.calls }
		guard call == 1 else { return LinkPreview(title: "Fresh") }
		await withCheckedContinuation { continuation in state.withLock { $0.gate = continuation } }
		return LinkPreview(title: "Stale")
	}
	func release() { state.withLock { $0.gate?.resume(); $0.gate = nil } }
	var waiting: Bool { state.withLock { $0.gate != nil } }
}

/// QuickLook stand-in: counts calls and succeeds or fails on demand.
final class CountingThumbnails: FileThumbnailing, @unchecked Sendable {
	var calls = 0
	var fail = false
	func thumbnail(for url: URL) async throws -> Data {
		calls += 1
		if fail { throw CocoaError(.fileReadUnknown) }
		return Data([0x89, 0x50, 0x4E, 0x47])
	}
}

@MainActor
@Suite struct PreviewerTests {
	func link() -> ClipDraft {
		ClipDraft(items: [PasteboardItemData([(PasteboardTypes.string, Data("https://example.com/post".utf8))])], copiedAt: .now)
	}

	func waitForState(_ store: ClipStore, _ key: String) async throws -> PreviewState? {
		for _ in 0..<200 {
			if let s = try await store.fetch(key)?.previewState, s != .pending { return s }
			try await Task.sleep(for: .milliseconds(10))
		}
		return nil
	}

	@Test func linkIsFetchedOnceAndSaved() async throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-prev-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = try ClipStore(directory: dir)
		let links = CountingLinks()
		let previewer = Previewer(store: store, links: links)
		let (clip, _) = try await store.insert(link())
		previewer.generate(for: clip)
		previewer.generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .okNoImage)
		#expect(links.calls == 1)
		#expect(try await store.fetch(clip.key)?.title == "A title")
		await previewer.resumePending()
		#expect(links.calls == 1)
		let reopened = try ClipStore(directory: dir)
		#expect(try await reopened.fetch(clip.key)?.title == "A title")
	}

	/// A copy carrying only `public.url` is saved with its URL as title and link, and its preview is requested for that URL.
	@Test func aURLOnlyCopyIsSavedAsALinkAndPreviewed() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let links = CountingLinks()
		let draft = ClipDraft(items: [PasteboardItemData([(PasteboardTypes.url, Data("https://example.com".utf8))])], copiedAt: .now)
		let (clip, _) = try await store.insert(draft)
		#expect(clip.kind == .link)
		#expect(clip.title == "https://example.com")
		#expect(clip.url == "https://example.com")
		#expect(clip.meta == "example.com")
		#expect(clip.previewState == .pending)
		Previewer(store: store, links: links).generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .okNoImage)
		#expect(links.urls == [URL(string: "https://example.com")!])
		#expect(try await store.fetch(clip.key)?.title == "A title")
	}

	@Test func failedFetchIsRecorded() async throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-prev-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = try ClipStore(directory: dir)
		let links = CountingLinks()
		links.result = .failure(URLError(.timedOut))
		let (clip, _) = try await store.insert(link())
		Previewer(store: store, links: links).generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .failed)
	}

	func tempStore() throws -> (ClipStore, URL) {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-prev-\(UUID().uuidString)")
		return (try ClipStore(directory: dir), dir)
	}

	func pngData(_ side: Int) throws -> Data {
		let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
			hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
		return try #require(rep.representation(using: .png, properties: [:]))
	}

	@Test func anImageIsDecodedOnceAtUtilityQoS() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let previewer = Previewer(store: store, links: CountingLinks())
		let (clip, _) = try await store.insert(ClipDraft(items: [PasteboardItemData([(PasteboardTypes.png, try pngData(900))])], copiedAt: .now))
		previewer.generate(for: clip)
		previewer.generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .ok)
		#expect(previewer.stats.decodes == 1)
		#expect(previewer.stats.priorities == [.utility])
		#expect(await store.thumbnail(for: clip.key) != nil)
	}

	@Test func aLinkWithOnlyASiteIconSavesTheIcon() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let links = CountingLinks()
		links.result = .success(LinkPreview(title: "Copia", icon: try pngData(64)))
		let (clip, _) = try await store.insert(link())
		Previewer(store: store, links: links).generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .okNoImage)
		#expect(await store.thumbnail(for: clip.key) != nil)
	}

	@Test func aFileThumbnailIsSavedAndReusedAfterARestart() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let thumbs = CountingThumbnails()
		let file = ClipDraft(items: [PasteboardItemData([(PasteboardTypes.fileURL, Data("file:///tmp/Design%20Review.key".utf8))])], copiedAt: .now)
		let (clip, _) = try await store.insert(file)
		Previewer(store: store, links: CountingLinks(), files: thumbs).generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .ok)
		#expect(thumbs.calls == 1)
		let reopened = try ClipStore(directory: dir)
		let again = Previewer(store: reopened, links: CountingLinks(), files: thumbs)
		await again.resumePending()
		if let stored = try await reopened.fetch(clip.key) { again.generate(for: stored) }
		try await Task.sleep(for: .milliseconds(50))
		#expect(thumbs.calls == 1)
		#expect(await reopened.thumbnail(for: clip.key) != nil)
	}

	@Test func aFileQuickLookCannotDrawFailsAndKeepsNoThumbnail() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let thumbs = CountingThumbnails()
		thumbs.fail = true
		let file = ClipDraft(items: [PasteboardItemData([(PasteboardTypes.fileURL, Data("file:///tmp/x.bin".utf8))])], copiedAt: .now)
		let (clip, _) = try await store.insert(file)
		Previewer(store: store, links: CountingLinks(), files: thumbs).generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .failed)
		#expect(await store.thumbnail(for: clip.key) == nil)
		#expect(try await store.fetch(clip.key)?.fileNames == ["x.bin"])
	}

	@Test func deleteAndUndoDuringAFetchKeepsOnlyTheFreshResult() async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let links = GatedLinks()
		let previewer = Previewer(store: store, links: links)
		var saves = 0
		previewer.onSaved = { saves += 1 }
		let (clip, _) = try await store.insert(link())
		previewer.generate(for: clip)
		while !links.waiting { try await Task.sleep(for: .milliseconds(5)) }
		let deleted = try #require(try await store.delete(clip.key))
		try await store.restore(deleted)
		let restored = try #require(try await store.fetch(clip.key))
		#expect(restored.generation != clip.generation)
		previewer.generate(for: restored)
		#expect(try await waitForState(store, clip.key) == .okNoImage)
		links.release()
		while saves < 2 { try await Task.sleep(for: .milliseconds(5)) }
		#expect(try await store.fetch(clip.key)?.title == "Fresh")
		#expect(links.calls == 2)
	}

	/// Undo after the trashed thumbnail was lost: the restored image asks again and ends whole, with a saved thumbnail.
	@Test func anUndoneImageWhoseTrashedThumbnailWasLostGetsItsPreviewBack() async throws {
		let faulty = FaultyFiles()
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-prev-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = try ClipStore(directory: dir, files: faulty)
		let previewer = Previewer(store: store, links: CountingLinks())
		let (clip, _) = try await store.insert(ClipDraft(items: [PasteboardItemData([(PasteboardTypes.png, try pngData(64))])], copiedAt: .now))
		previewer.generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .ok)
		let deleted = try #require(try await store.delete(clip.key))
		faulty.failRemoveContaining = "trash/\(clip.key).plist"
		await store.emptyTrash()
		try await store.restore(deleted)
		await previewer.resumePending()
		#expect(try await waitForState(store, clip.key) == .ok)
		#expect(await store.thumbnail(for: clip.key) != nil)
		#expect(previewer.stats.decodes == 2)
	}

	@Test func imageThumbnailIsAtMost480Pixels() throws {
		let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4,
			hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
		let png = try #require(rep.representation(using: .png, properties: [:]))
		let thumb = try #require(Previewer.thumbnailPNG(from: png))
		let out = try #require(NSBitmapImageRep(data: thumb))
		#expect(max(out.pixelsWide, out.pixelsHigh) <= 480)
		#expect(out.hasAlpha)
	}
}
