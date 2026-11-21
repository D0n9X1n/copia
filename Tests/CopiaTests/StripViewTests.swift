import Testing
import AppKit
import SwiftUI
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

/// StripView hosted in a real (off-screen, transparent) window, observed through its accessibility tree.
@MainActor
@Suite(.serialized) struct StripViewTests {
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
			badge: nil, hovered: false, selected: false, removing: false, now: Fixtures.now, highlight: "",
			thumbnails: ThumbnailCache(), animator: .immediate))
		window.contentView?.layoutSubtreeIfNeeded()
		#expect(Diagnostics.bodyEvaluations > before)
	}
}
