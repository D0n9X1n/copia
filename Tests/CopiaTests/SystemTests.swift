import Testing
import AppKit
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
	func readItems() -> [PasteboardItemData] { reads += 1; return items }
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
	var result: Result<(String?, Data?), Error> = .success(("A title", nil))
	func fetch(_ url: URL) async throws -> (title: String?, image: Data?) {
		calls += 1
		return try result.get()
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
