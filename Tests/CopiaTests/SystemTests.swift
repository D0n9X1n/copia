import Testing
import AppKit
import Synchronization
import CopiaCore
@testable import CopiaStore
@testable import CopiaSystem

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

	@Test func pollingTimerUsesHalfSecondCadenceAndOneTenthTolerance() {
		let pb = FakePasteboard()
		let (w, drafts) = make(pb)
		let timer = w.makeTimer()
		defer { timer.invalidate() }
		#expect(timer.timeInterval == 0.5)
		#expect(timer.tolerance == 0.1)
		pb.copy("timer copy")
		#expect(pb.reads == 0)
		timer.fire()
		#expect(drafts().first.map(Capture.plainText) == "timer copy")
		#expect(pb.reads == 1)
		#expect(timer.isValid)
	}

	@Test func pollingTimerDoesNotRetainAnAbandonedWatcher() {
		let pb = FakePasteboard()
		var watcher: PasteboardWatcher? = PasteboardWatcher(source: pb, frontmost: { nil })
		weak var weakWatcher = watcher
		let timer = watcher!.makeTimer()
		defer { timer.invalidate() }
		watcher = nil
		#expect(weakWatcher == nil)
		timer.fire()
		#expect(!timer.isValid)
		#expect(pb.reads == 0)
	}

	@Test func pollingCallbackStillSkipsPrivateAndPausedContents() {
		let pb = FakePasteboard()
		let (watcher, drafts) = make(pb)
		let timer = watcher.makeTimer()
		defer { timer.invalidate() }
		pb.copy("private fixture", extraTypes: ["org.nspasteboard.ConcealedType"])
		timer.fire()
		watcher.setPaused(true)
		pb.copy("paused fixture")
		timer.fire()
		#expect(pb.reads == 0 && drafts().isEmpty)
		watcher.setPaused(false)
		pb.copy("allowed fixture")
		timer.fire()
		#expect(drafts().count == 1)
		#expect(drafts().first.map(Capture.plainText) == "allowed fixture")
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

	@Test func resumingWithoutAPausedTickNeverCapturesThePausedCopy() {
		let pb = FakePasteboard()
		let (w, drafts) = make(pb)
		w.setPaused(true)
		pb.copy("while paused")
		w.setPaused(false)
		w.tick()
		#expect(drafts().isEmpty)
		#expect(pb.reads == 0)
		pb.copy("after resume")
		w.tick()
		#expect(drafts().count == 1)
		#expect(drafts().first.map(Capture.plainText) == "after resume")
		#expect(pb.reads == 1)
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
	func pasteboard() -> NSPasteboard { .withUniqueName() }

	/// Guard the writer's capability boundary without probing the live clipboard, Accessibility, or another app.
	@Test func writerDoesNotAcquireExternalCapabilities() throws {
		let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		let source = try String(contentsOf: root.appendingPathComponent("Sources/CopiaSystem/Paster.swift"), encoding: .utf8)
		for api in [".general", "CGEvent", "AXIsProcessTrusted", "NSWorkspace", "NSRunningApplication", "FileManager",
			"URLSession", "NSFilePromiseProvider", "Data(contentsOf:", ".write(to:"] {
			#expect(!source.contains(api), "The copy writer must not acquire \(api)")
		}
	}

	@Test func unconvertiblePlainCopyLeavesThePasteboardUntouched() throws {
		let pb = pasteboard()
		defer { pb.releaseGlobally() }
		try #require(pb.setString("keep me", forType: .string))
		let before = pb.changeCount
		let image = PasteboardItemData([(PasteboardTypes.png, Data([0x89, 0x50]))])
		#expect(throws: (any Error).self) { try Paster(pasteboard: pb).write([image], plain: true) }
		#expect(pb.changeCount == before)
		#expect(pb.string(forType: .string) == "keep me")
	}

	@Test func emptyCopiesLeaveThePasteboardUntouched() throws {
		let pb = pasteboard()
		defer { pb.releaseGlobally() }
		try #require(pb.setString("keep me", forType: .string))
		let before = pb.changeCount
		for items in [[], [PasteboardItemData([])]] {
			#expect(throws: (any Error).self) { try Paster(pasteboard: pb).write(items, plain: false) }
		}
		#expect(pb.changeCount == before)
		#expect(pb.string(forType: .string) == "keep me")
	}

	@Test func rejectedRepresentationDoesNotClearThePasteboard() throws {
		let pb = pasteboard()
		defer { pb.releaseGlobally() }
		try #require(pb.setString("keep me", forType: .string))
		let before = pb.changeCount
		let item = PasteboardItemData([(PasteboardTypes.string, Data("new".utf8)), ("", Data())])
		#expect(throws: (any Error).self) { try Paster(pasteboard: pb).write([item], plain: false) }
		#expect(pb.changeCount == before)
		#expect(pb.string(forType: .string) == "keep me")
	}

	@Test func rejectedWriteThrowsEvenWhenAllItemsWerePrepared() throws {
		let pb = pasteboard()
		defer { pb.releaseGlobally() }
		var offered: [String] = []
		let writer = Paster(pasteboard: pb, writeObjects: { items in
			offered = items.compactMap { $0.string(forType: .string) }
			return false
		})
		let items = [PasteboardItemData([(PasteboardTypes.string, Data("new".utf8))])]
		#expect(throws: (any Error).self) { try writer.write(items, plain: false) }
		#expect(offered == ["new"])
	}

	@Test func writePreservesItemsAndRepresentationsWithoutMaterializingFiles() throws {
		let pb = pasteboard()
		defer { pb.releaseGlobally() }
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
		defer { try? FileManager.default.removeItem(at: dir) }
		let file = dir.appendingPathComponent("Design Review.key", isDirectory: false)
		let mixed = PasteboardItemData([(PasteboardTypes.html, Data("<b>hi</b>".utf8)),
			(PasteboardTypes.string, Data("hi".utf8)), (PasteboardTypes.rtf, Data(#"{\rtf1 hi}"#.utf8)),
			(PasteboardTypes.png, Data([0x89, 0x50, 0x4E, 0x47]))])
		let items = [mixed, PasteboardItemData([(PasteboardTypes.fileURL, Data(file.absoluteString.utf8))]),
			PasteboardItemData([(PasteboardTypes.url, Data("https://example.invalid/fixture".utf8))])]
		try Paster(pasteboard: pb).write(items, plain: false)
		let written = try #require(pb.pasteboardItems)
		#expect(written.count == items.count)
		for (out, input) in zip(written, items) {
			// AppKit may advertise extra translations; check the original representations in their order.
			let types = input.representations.map(\.type)
			#expect(out.types.map(\.rawValue).filter(types.contains) == types)
			for rep in input.representations { #expect(out.data(forType: .init(rep.type)) == rep.data) }
			#expect(out.data(forType: .init(PasteboardTypes.marker)) == Data())
			#expect(out.string(forType: .init(PasteboardTypes.source)) == (Bundle.main.bundleIdentifier ?? "app.copia.Copia"))
		}
		#expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
	}

	@Test func plainCopyStripsFormattingAndUsesLexicalFilePathsInItemOrder() throws {
		let pb = pasteboard()
		defer { pb.releaseGlobally() }
		let items = [PasteboardItemData([(PasteboardTypes.html, Data("<p>not chosen</p>".utf8)),
			(PasteboardTypes.string, Data("string wins".utf8))]),
			PasteboardItemData([(PasteboardTypes.string, Data([0xff])), (PasteboardTypes.rtf, Data()),
				(PasteboardTypes.html, Data("<p>valid fallback</p>".utf8))]),
			PasteboardItemData([(PasteboardTypes.png, Data([0x89]))]),
			PasteboardItemData([(PasteboardTypes.html, Data("<p>Ship <b>it</b></p>".utf8))]),
			PasteboardItemData([(PasteboardTypes.rtf, Data(#"{\rtf1 rich}"#.utf8))]),
			PasteboardItemData([(PasteboardTypes.url, Data("https://example.invalid/fixture".utf8))]),
			PasteboardItemData([(PasteboardTypes.fileURL, Data("file:///tmp/Design%20Review.key".utf8))]),
			PasteboardItemData([(PasteboardTypes.fileURL, Data("file:///.file/id=9999999.9999999".utf8))])]
		try Paster(pasteboard: pb).write(items, plain: true)
		let written = try #require(pb.pasteboardItems)
		#expect(written.compactMap { $0.string(forType: .string) } == ["string wins", "valid fallback", "Ship it", "rich",
			"https://example.invalid/fixture", "/tmp/Design Review.key", "/.file/id=9999999.9999999"])
		for item in written {
			#expect(item.types.map(\.rawValue).filter(PasteboardTypes.stored.contains) == [PasteboardTypes.string])
			#expect(item.data(forType: .init(PasteboardTypes.marker)) == Data())
			#expect(item.string(forType: .init(PasteboardTypes.source)) == (Bundle.main.bundleIdentifier ?? "app.copia.Copia"))
		}
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
	var urls: [URL] = []
	var fail = false
	func thumbnail(for url: URL) async throws -> Data {
		calls += 1
		urls.append(url)
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

	@Test(arguments: [false, true], [Data(), Data([0xFF])])
	func aLaterImagePreservesItemOrderAndPrefersPNGWithinAnItem(firstHasPNG: Bool, leadingText: Data) async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let links = CountingLinks()
		let thumbs = CountingThumbnails()
		let previewer = Previewer(store: store, links: links, files: thumbs)
		let tiff = try #require(NSBitmapImageRep(data: try pngData(48))?.tiffRepresentation)
		var representations = [(PasteboardTypes.tiff, tiff)]
		if firstHasPNG { representations.append((PasteboardTypes.png, try pngData(32))) }
		// Image classification requires empty text; exercise supported image clips whose image is not item zero.
		let items = [PasteboardItemData([(PasteboardTypes.string, leadingText)]),
			PasteboardItemData(representations), PasteboardItemData([(PasteboardTypes.png, try pngData(80))])]
		let (clip, _) = try await store.insert(ClipDraft(items: items, copiedAt: .now))
		#expect(clip.kind == .image)
		previewer.generate(for: clip)
		previewer.generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .ok)
		#expect(previewer.stats.decodes == 1)
		#expect(previewer.stats.priorities == [.utility])
		#expect(links.calls == 0)
		#expect(thumbs.calls == 0)
		let thumbnail = try #require(await store.thumbnail(for: clip.key))
		let image = try #require(NSBitmapImageRep(data: try Data(contentsOf: thumbnail)))
		#expect(image.pixelsWide == (firstHasPNG ? 32 : 48))
		#expect(image.pixelsHigh == image.pixelsWide)
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

	@Test(arguments: [false, true])
	func aFileAfterADescriptionPreviewsTheFirstSupportedURL(skippingMalformedItems: Bool) async throws {
		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let links = CountingLinks()
		let thumbs = CountingThumbnails()
		let previewer = Previewer(store: store, links: links, files: thumbs)
		let firstURL = URL(fileURLWithPath: "/tmp/Design Review.key")
		var items = [PasteboardItemData([(PasteboardTypes.string, Data("File description".utf8))])]
		if skippingMalformedItems {
			items.append(PasteboardItemData([(PasteboardTypes.fileURL, Data([0xFF]))]))
			items.append(PasteboardItemData([(PasteboardTypes.fileURL, Data("http://[".utf8))]))
		}
		items += [firstURL, URL(fileURLWithPath: "/tmp/later.txt")].map {
			PasteboardItemData([(PasteboardTypes.fileURL, Data($0.absoluteString.utf8))])
		}
		let (clip, _) = try await store.insert(ClipDraft(items: items, copiedAt: .now))
		#expect(clip.kind == .file)
		previewer.generate(for: clip)
		previewer.generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .ok)
		#expect(await store.thumbnail(for: clip.key) != nil)
		#expect(thumbs.calls == 1)
		#expect(thumbs.urls == [firstURL])
		#expect(links.calls == 0)
		#expect(previewer.stats.decodes == 0)
		#expect(previewer.stats.priorities == [.utility])
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

	/// Closing expires the undo even if a snapshot cannot be unlinked; leftover bytes do not authorize restore.
	@Test func closingWithSnapshotCleanupFailureDoesNotRegenerateAPreview() async throws {
		let faulty = FaultyFiles()
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-prev-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = try ClipStore(directory: dir, files: faulty)
		let previewer = Previewer(store: store, links: CountingLinks())
		let (clip, _) = try await store.insert(ClipDraft(items: [PasteboardItemData([(PasteboardTypes.png, try pngData(64))])], copiedAt: .now))
		previewer.generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .ok)
		let deleted = try #require(try await store.delete(clip.key))
		faulty.failRemoveContaining = deleted.token.uuidString + ".plist"
		await store.emptyTrash()
		#expect(await store.cleanupPending)
		await #expect(throws: StoreError.undoExpired) { try await store.restore(deleted) }
		await previewer.resumePending()
		#expect(try await store.fetch(clip.key) == nil)
		#expect(await store.thumbnail(for: clip.key) == nil)
		#expect(previewer.stats.decodes == 1)
		try await store.removeOrphans()
		#expect(!(await store.cleanupPending))
	}

	@Test func finalizedLinkUndoPreservesSavedPreviewWithoutRefetch() async throws {
		let faulty = FaultyFiles()
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-prev-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = try ClipStore(directory: dir, files: faulty)
		let links = CountingLinks(), previewer = Previewer(store: store, links: links)
		let (clip, _) = try await store.insert(link())
		let image = try pngData(64)
		#expect(try await store.setPreview(key: clip.key, generation: clip.generation, state: .ok, title: "Saved", image: image))
		let deleted = try #require(try await store.delete(clip.key))
		faulty.failCopyContaining = ".png"
		await #expect(throws: (any Error).self) { try await store.restore(deleted) }
		#expect(try await store.fetch(clip.key) == nil)
		let restored = try await store.restore(deleted)
		#expect(restored.previewState == .ok && restored.title == "Saved")
		let thumbnail = try #require(await store.thumbnail(for: clip.key))
		#expect(try Data(contentsOf: thumbnail) == image)
		previewer.generate(for: restored)
		await previewer.resumePending()
		#expect(links.calls == 0)
	}

	/// An 8000×8000 PNG (brief:79) through the real capture, store and thumbnail path: its footer gives its size,
	/// and its saved thumbnail is at most 384 px, enough for a 192 pt card at 2×.
	@Test func an8000PixelImageIsCapturedStoredAndThumbnailed() async throws {
		let png = try Self.solidPNG(side: 8000)
		let pb = FakePasteboard()
		var drafts: [ClipDraft] = []
		let watcher = PasteboardWatcher(source: pb, frontmost: { "com.apple.Preview" }, appName: { _ in "Preview" })
		watcher.onDraft = { drafts.append($0) }
		pb.changeCount += 1
		pb.items = [PasteboardItemData([(PasteboardTypes.png, png)])]
		pb.typeIdentifiers = [PasteboardTypes.png]
		watcher.tick()
		let draft = try #require(drafts.first)

		let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
		let previewer = Previewer(store: store, links: CountingLinks())
		let (clip, _) = try await store.insert(draft)
		#expect(clip.kind == .image)
		#expect(clip.meta == "8000×8000 · PNG")
		previewer.generate(for: clip)
		#expect(try await waitForState(store, clip.key) == .ok)
		let thumb = try #require(await store.thumbnail(for: clip.key))
		let image = try #require(NSBitmapImageRep(data: try Data(contentsOf: thumb)))
		#expect(max(image.pixelsWide, image.pixelsHigh) <= 384)
		#expect(image.pixelsWide == image.pixelsHigh)
		#expect(previewer.stats.decodes == 1)
		#expect(previewer.stats.priorities == [.utility])
	}

	/// A solid 8-bit grayscale PNG: 64 MB to draw, a few hundred KB encoded.
	static func solidPNG(side: Int) throws -> Data {
		guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
			space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw CocoaError(.featureUnsupported) }
		ctx.setFillColor(gray: 0.5, alpha: 1)
		ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
		let out = NSMutableData()
		guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)
		else { throw CocoaError(.featureUnsupported) }
		CGImageDestinationAddImage(dest, image, nil)
		guard CGImageDestinationFinalize(dest) else { throw CocoaError(.featureUnsupported) }
		return out as Data
	}

	@Test func imageThumbnailIsAtMost384Pixels() throws {
		let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4,
			hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
		let png = try #require(rep.representation(using: .png, properties: [:]))
		let thumb = try #require(Previewer.thumbnailPNG(from: png))
		let out = try #require(NSBitmapImageRep(data: thumb))
		#expect(max(out.pixelsWide, out.pixelsHigh) <= 384)
		#expect(out.hasAlpha)
	}
}
