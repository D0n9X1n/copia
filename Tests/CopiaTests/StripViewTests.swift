import Testing
import Observation
import AppKit
import SwiftUI
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

@MainActor @Observable private final class AgeClock { var date = Fixtures.now }

extension WindowTests {
	/// StripView hosted in a real (off-screen, transparent) window, observed through its accessibility tree.
	@MainActor @Suite struct StripViewTests {}
}

extension WindowTests.StripViewTests {
	@Test func openSlidesTheStripUpFromBelowItsFullHeight() async throws {
		let height = Theme.panelHeight, margin: CGFloat = 16, width: CGFloat = 1440
		let normal = CopiaOverrides(reduceMotion: false)
		let host = StripHost(width: width, overrides: normal, appear: false)
		defer { host.close() }
		// Observe the moving strip inside a larger viewport; a fully clipped element can be absent from AX.
		// Keep the production layout fixed so the extra observation space does not move its Spacer.
		host.window.setContentSize(CGSize(width: width, height: height * 2 + margin * 2))
		host.window.contentView = NSHostingView(rootView:
			StripView(model: host.model, focus: SearchFocus(), thumbnails: ThumbnailCache(), now: { Fixtures.now })
				.environment(\.copiaOverrides, normal)
				.frame(width: width, height: height)
				.padding(.top, margin).padding(.bottom, height + margin))
		await host.settle()
		let panelBottom = host.window.frame.minY + height + margin
		let hidden = try #require(host.strip).frame
		#expect(host.window.frame.contains(hidden))
		#expect(abs(hidden.maxY - panelBottom) < 0.5)
		#expect(abs(hidden.height - height) < 0.5)
		host.model.animateIn()
		await host.settle()
		let shown = try #require(host.strip).frame
		#expect(abs(shown.minY - panelBottom) < 0.5)
		#expect(abs(shown.minY - hidden.minY - height) < 0.5)
		#expect(shown.size == hidden.size)
		#expect(abs(shown.minX - hidden.minX) < 0.5)
		#expect(host.requests == [.open])

		let production = StripHost(overrides: normal)
		defer { production.close() }
		await production.settle()
		let visible = try #require(production.strip).frame
		#expect(abs(visible.minY - production.window.frame.minY) < 0.5)
		#expect(abs(visible.height - height) < 0.5)
	}

	@Test func storageWarningsRemainVisibleAfterTransientToastsEnd() async throws {
		let host = StripHost(overrides: CopiaOverrides(reduceMotion: true))
		defer { host.close() }
		let clock = ClockProbe()
		host.model.clock = clock.clock
		host.model.storageStatus = .cleanupPending
		await host.model.deleteSelected()
		#expect(host.model.toast == .deleted)
		await host.settle()
		#expect(host.root.all.contains { $0.label == StorageStatus.cleanupPending.message || $0.value == StorageStatus.cleanupPending.message })
		clock.advance(by: .seconds(3))
		#expect(host.model.toast == nil)
		for status in [StorageStatus.cleanupPending, .recoveryRequired] {
			host.model.storageStatus = status
			await host.settle()
			let warning = try #require(host.root.all.first { $0.value == status.message || $0.label == status.message })
			#expect(host.isOnScreen(warning))
			#expect(host.window.frame.contains(warning.frame))
			#expect(warning.frame.minY >= host.window.frame.maxY - Theme.topBarHeight, "storage warning must not cover cards")
		}
	}

	@Test func recoveryHeaderFitsTheCIWidthWithAnExpandedSearchField() async throws {
		let host = StripHost(width: 1008, overrides: CopiaOverrides(reduceMotion: true))
		defer { host.close() }
		host.model.storageStatus = .recoveryRequired
		host.model.paused = true
		host.model.query = "example"
		await host.settle()
		let warning = try #require(host.root.all.first { $0.label == StorageStatus.recoveryRequired.message || $0.value == StorageStatus.recoveryRequired.message })
		#expect(host.isOnScreen(warning))
		#expect(warning.frame.minY >= host.window.frame.maxY - Theme.topBarHeight)
		func searchField(in view: NSView) -> NSTextField? {
			if let field = view as? NSTextField, field.accessibilityLabel() == "Search clipboard history" { return field }
			return view.subviews.lazy.compactMap { searchField(in: $0) }.first
		}
		let field = try #require(host.window.contentView.flatMap { searchField(in: $0) })
		let frame = host.window.convertToScreen(field.convert(field.bounds, to: nil))
		#expect(frame.maxX < warning.frame.minX)
	}

	@Test func aNewCopyWhileOpenSlidesInAtIndexZeroAndTheSelectionStaysInView() async throws {
		let host = StripHost(width: 1000)
		defer { host.close() }
		let selected = Fixtures.mixed[3]
		host.model.select(selected.id)
		await host.settle()
		#expect(host.card(containing: "Screenshot").map(host.isOnScreen) == true)

		host.model.applySnapshot([Fixtures.extremes[0]] + Fixtures.mixed)
		await host.settle(300)
		#expect(host.model.selectedID == selected.id)
		#expect(host.model.visibleClips.first?.id == Fixtures.extremes[0].id)
		#expect(host.requests.contains(.insert))
		let card = try #require(host.card(containing: "Screenshot"))
		#expect(host.isOnScreen(card))
	}

	@Test func undoPutsTheCardBackAtItsIndexAndScrollsItIntoView() async throws {
		let host = StripHost(width: 1000)
		defer { host.close() }
		let last = Fixtures.mixed[8]
		host.model.moveToEnd(true)
		await host.settle()
		await host.model.deleteSelected()
		host.model.moveToEnd(false)
		await host.settle(300)
		await host.model.undo()
		await host.settle(300)
		#expect(host.model.clips[8].id == last.id)
		#expect(host.model.selectedID == last.id)
		#expect(host.requests.contains(.undo))
		let card = try #require(host.card(containing: "3 files"))
		#expect(host.isOnScreen(card))
	}

	@Test func liveDeleteKeepsItsSlotUntilTheOutgoingFadeFinishes() async throws {
		for reduced in [false, true] {
			let host = StripHost(overrides: .init(reduceMotion: reduced))
			defer { host.close() }
			await host.settle()
			let id = try #require(host.model.selectedID)
			let live = Animator.live { reduced }
			var start: ContinuousClock.Instant?, reflow: Duration?
			host.model.animator = Animator { event, change, completion in
				if event == .delete { start = .now }
				if event == .reflow, let start { reflow = .now - start }
				live.run(event, change, completion)
			}
			await host.model.deleteSelected()
			await host.settle(600)
			let elapsed = try #require(reflow)
			#expect(elapsed >= (reduced ? .milliseconds(145) : .milliseconds(195)), "reduced=\(reduced), reflow at \(elapsed)")
			#expect(!host.model.clips.contains { $0.id == id })
		}
	}

	@Test func clockUpdatesInvalidateACardOnlyWhenItsDisplayedAgeChanges() async throws {
		let clock = AgeClock()
		var clip = Fixtures.mixed[0]; clip.timestamp = Fixtures.now.addingTimeInterval(-58)
		let host = StripHost(clips: [clip], now: { clock.date })
		defer { host.close() }; await host.settle()
		#expect(try #require(host.cards.first).label.contains(", just now: "))
		let initialBodies = Diagnostics.bodyEvaluations
		clock.date = Fixtures.now.addingTimeInterval(1); await host.settle()
		#expect(Diagnostics.bodyEvaluations == initialBodies)
		#expect(try #require(host.cards.first).label.contains(", just now: "))
		clock.date = Fixtures.now.addingTimeInterval(2); await host.settle()
		#expect(Diagnostics.bodyEvaluations > initialBodies)
		#expect(try #require(host.cards.first).label.contains(", 1m ago: "))
	}

	@Test func firstOpenDefersOffscreenThumbnailsUntilTheRowMoves() async throws {
		actor Decodes {
			var urls: Set<URL> = []
			func record(_ url: URL) { urls.insert(url) }
		}
		let decodes = Decodes()
		let cache = ThumbnailCache { url in await decodes.record(url); return nil }
		var clips = Array(Fixtures.tenThousand.prefix(20))
		let visible = URL(fileURLWithPath: "/fixture/visible-preview"), later = URL(fileURLWithPath: "/fixture/offscreen-preview")
		clips[0].preview = .ready(visible); clips[6].preview = .ready(later)
		let host = StripHost(clips: clips, width: 900, thumbnails: cache, overrides: .init(reduceMotion: true))
		defer { host.close() }
		await host.settle()
		let initial = await decodes.urls
		#expect(initial == [visible])
		host.model.select(clips[6].id); await host.settle()
		#expect(await decodes.urls.contains(later))
		let selected = try #require(host.card(containing: "History item 7"))
		#expect(host.isOnScreen(selected))
	}

	@Test func responsiveScrollingPreparesOnlyMountedCardContent() async throws {
		let host = InputHost(clips: Array(Fixtures.tenThousand.prefix(100))); defer { host.close() }; await host.settle()
		func findRow(_ view: NSView) -> NSScrollView? {
			if let scroll = view as? NSScrollView, !(scroll.documentView is NSTextView) { return scroll }
			return view.subviews.lazy.compactMap { findRow($0) }.first
		}
		let row = try #require(findRow(host.panel.host)), document = try #require(row.documentView)
		let cards = try #require(document.subviews.first)
		#expect(type(of: document).isCompatibleWithResponsiveScrolling)
		#expect(type(of: row).isCompatibleWithResponsiveScrolling)
		for slot in [0, 60, 99] {
			let target = min(PanelLayout.cardMinX(index: slot), document.bounds.width - row.contentView.bounds.width)
			row.contentView.scroll(to: CGPoint(x: target, y: 0)); row.reflectScrolledClipView(row.contentView); await host.settle()
			let viewport = document.bounds.intersection(row.contentView.bounds)
			try #require(!viewport.isEmpty)
			let left = slot == 0 ? document.bounds.minX : cards.frame.minX
			let right = slot == 99 ? document.bounds.maxX : cards.frame.maxX
			let backed = CGRect(x: left, y: cards.frame.minY, width: right - left, height: cards.frame.height)
			#expect(document.preparedContentRect.contains(viewport))
			document.prepareContent(in: document.bounds)
			let prepared = document.preparedContentRect
			#expect(prepared == backed && prepared.contains(viewport))
			#expect(prepared.width < 30 * (Theme.cardSize.width + Theme.cardGap))
			let distant = CGRect(x: slot == 0 ? document.bounds.maxX - 32 : 1, y: 1, width: 16, height: 16)
			try #require(!distant.intersects(cards.frame))
			document.prepareContent(in: distant)
			let after = document.preparedContentRect
			#expect(after.contains(viewport) && backed.contains(after) && !after.intersects(distant))
			let x = viewport.maxX + 20 < backed.maxX ? viewport.maxX + 2 : viewport.minX - 18
			let ahead = CGRect(x: x, y: viewport.midY, width: 16, height: 16)
			try #require(backed.contains(ahead) && !viewport.intersects(ahead))
			document.prepareContent(in: ahead)
			let partial = document.preparedContentRect
			#expect(partial.contains(viewport) && partial.contains(ahead) && backed.contains(partial))
		}
		host.model.applySnapshot(Array(host.model.clips.prefix(5))); await host.settle()
		let shrunk = document.preparedContentRect
		let viewportAfterShrink = document.bounds.intersection(row.contentView.bounds)
		try #require(!viewportAfterShrink.isEmpty)
		#expect(shrunk.contains(viewportAfterShrink) && document.bounds.contains(shrunk))
		#expect(document.bounds.width == PanelLayout.contentWidth(count: 5))
	}

	@Test func prependingWhileScrolledKeepsTheVisibleClipsInFlightPreview() async throws {
		actor Loads {
			var count = 0
			var waiting: [CheckedContinuation<CGImage?, Never>] = []
			func start() async -> CGImage? {
				count += 1
				return await withCheckedContinuation { waiting.append($0) }
			}
			func finish() { waiting.forEach { $0.resume(returning: nil) }; waiting.removeAll() }
		}
		let loads = Loads(), cache = ThumbnailCache { _ in await loads.start() }, index = 9
		var clips = Array(Fixtures.tenThousand.prefix(24)); clips[index].preview = .ready(URL(fileURLWithPath: "/fixture/page-boundary-preview"))
		let host = StripHost(clips: clips, width: 900, thumbnails: cache); defer { host.close() }
		await host.settle(); host.model.select(clips[index].id); await host.settle(450)
		let original = await loads.count
		host.model.applySnapshot([Fixtures.extremes[0]] + clips); await host.settle(200)
		let inserted = await loads.count, same = host.card(containing: "History item 10").map(host.isOnScreen)
		host.model.applySnapshot(clips); await host.settle(200)
		let restored = await loads.count; await loads.finish()
		#expect(original == 1 && inserted == original && restored == original)
		#expect(same == true && host.model.selectedID == clips[index].id)
	}

	@Test func frontDeleteKeepsTheTrailingCardMountedAcrossReflowWithoutScrolling() async throws {
		actor Decodes {
			var calls: [URL: Int] = [:]
			func record(_ url: URL) { calls[url, default: 0] += 1 }
		}
		let decodes = Decodes()
		let cache = ThumbnailCache { url in await decodes.record(url); return nil }
		var clips = Array(Fixtures.tenThousand.prefix(20))
		let entering = URL(fileURLWithPath: "/fixture/trailing-moving-card")
		let stayingOutside = URL(fileURLWithPath: "/fixture/trailing-offscreen-card")
		let distant = URL(fileURLWithPath: "/fixture/distant-card")
		clips[4].preview = .ready(entering); clips[5].preview = .ready(stayingOutside); clips[7].preview = .ready(distant)
		let host = StripHost(clips: clips, width: 900, thumbnails: cache, overrides: .init(reduceMotion: false))
		defer { host.close() }; await host.settle()
		host.model.animator = .live { false }
		let before = await decodes.calls
		#expect(before == [entering: 1, stayingOutside: 1])
		await host.model.deleteSelected(); await host.settle(650)
		#expect(host.model.visibleClips[3].id == clips[4].id)
		#expect(host.card(containing: "History item 5") != nil)
		#expect(await decodes.calls == before)
	}

	@Test func fourthCardKeepsItsInFlightPreviewAcrossInsertionAndRemoval() async throws {
		actor DecodeProbe {
			var calls = 0
			var waiting: [CheckedContinuation<CGImage?, Never>] = []
			func load() async -> CGImage? {
				calls += 1
				return await withCheckedContinuation { waiting.append($0) }
			}
			func finish() { waiting.forEach { $0.resume(returning: nil) }; waiting.removeAll() }
		}
		let probe = DecodeProbe()
		let cache = ThumbnailCache { _ in await probe.load() }
		var clips = Array(Fixtures.mixed.prefix(6))
		clips[3].preview = .ready(URL(fileURLWithPath: "/fixture/owned-by-decoder"))
		let host = StripHost(clips: clips, width: 1496, thumbnails: cache, overrides: .init(reduceMotion: false))
		defer { host.close() }
		await host.settle()
		let before = await probe.calls
		host.model.applySnapshot([Fixtures.extremes[0]] + clips)
		await host.settle()
		let afterInsert = await probe.calls
		host.model.applySnapshot(clips)
		await host.settle()
		let afterDelete = await probe.calls
		await probe.finish()
		#expect(before == 1)
		#expect(afterInsert == before && afterDelete == before)
	}

	@Test func previewLoadingRunsThroughTheMotionTable() async throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copia-loading-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let assets = try FixtureAssets.prepare(in: dir)
		let host = StripHost(clips: assets.mixed)
		defer { host.close() }
		for _ in 0..<60 where !host.requests.contains(.loading) { await host.settle(50) }
		#expect(host.requests.contains(.loading))
	}

	@Test func theCardSheetShowsEveryExtremeAtOnceOnAStageSizedSheet() async {
		AccessibilityNode.enableInProcess()
		let clips = Fixtures.extremes + [Fixtures.failed, Fixtures.pending]
		let host = NSHostingView(rootView: CardSheet(clips: clips, thumbnails: ThumbnailCache(), now: Fixtures.now))
		let size = host.fittingSize
		#expect(size.width <= 1440 && size.height <= 900)
		let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -6000, y: -6000), size: size),
			styleMask: .borderless, backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.alphaValue = 0
		defer { window.orderOut(nil) }
		window.contentView = host
		window.orderFrontRegardless()
		try? await Task.sleep(for: .milliseconds(150))
		host.layoutSubtreeIfNeeded()
		let labels = Set(AXNode(host).all.map(\.label))
		for clip in clips {
			#expect(labels.contains(CardAccessibility(clip: clip, now: Fixtures.now).label))
		}
	}

	@Test func closingSlidesDownAndFadesWhileOpeningOnlySlides() {
		// Open with motion: a slide, no fade. Open with Reduce Motion: a fade in place.
		#expect(StripView.stripOpacity(appeared: false, closing: false, reduced: false) == 1)
		#expect(StripView.stripOpacity(appeared: true, closing: false, reduced: false) == 1)
		#expect(StripView.stripOpacity(appeared: false, closing: false, reduced: true) == 0)
		// Close: the strip fades out as it slides down, with or without Reduce Motion.
		#expect(StripView.stripOpacity(appeared: false, closing: true, reduced: false) == 0)
		#expect(StripView.stripOpacity(appeared: false, closing: true, reduced: true) == 0)
	}

	@Test func theCloseAnimationChangesTheStripToItsClosingState() {
		let model = StripModel(clips: Fixtures.mixed)
		var seen: (appeared: Bool, closing: Bool)?
		model.animator = Animator { event, change, _ in
			change()
			if event == .close { seen = (model.appeared, model.isClosing) }
		}
		model.open()
		model.animateIn()
		model.beginClose()
		// Inside the close animation the strip is not appeared and is closing: it slides down and fades.
		#expect(seen?.appeared == false && seen?.closing == true)
		#expect(StripView.stripOpacity(appeared: model.appeared, closing: model.isClosing, reduced: false) == 0)
	}

	@Test func theOpenSlideDoesNotRebuildTheStripOrItsCards() async {
		let host = StripHost(appear: false)
		defer { host.close() }
		await host.settle()
		// No suspension from here on, so no other test can touch the counter.
		let before = Diagnostics.bodyEvaluations
		host.model.animateIn()
		host.window.contentView?.layoutSubtreeIfNeeded()
		#expect(host.model.appeared)
		#expect(Diagnostics.bodyEvaluations == before)
	}

	@Test func stripAndCardBodiesCountTheirEvaluations() {
		_ = NSApplication.shared
		let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 600, height: Theme.panelHeight),
			styleMask: .borderless, backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		defer { window.orderOut(nil) }

		var before = Diagnostics.bodyEvaluations
		window.contentView = NSHostingView(rootView: StripView(model: StripModel(clips: []), focus: SearchFocus(),
			thumbnails: ThumbnailCache()))
		window.contentView?.layoutSubtreeIfNeeded()
		#expect(Diagnostics.bodyEvaluations > before)

		before = Diagnostics.bodyEvaluations
		window.contentView = NSHostingView(rootView: ClipCard(clip: Fixtures.mixed[0], tint: Theme.neutralTint, icon: nil,
			badge: nil, hovered: false, selected: false, removing: false, age: ClipCard.relative(Fixtures.mixed[0].timestamp, now: Fixtures.now), highlight: "",
			thumbnails: ThumbnailCache(), animator: .immediate))
		window.contentView?.layoutSubtreeIfNeeded()
		#expect(Diagnostics.bodyEvaluations > before)
	}
}
