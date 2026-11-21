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
		let host = StripHost(appear: false)
		defer { host.close() }
		await host.settle()
		let hidden = try #require(host.strip)
		#expect(hidden.frame.maxY <= host.window.frame.minY + 0.5)
		host.model.animateIn()
		await host.settle()
		let shown = try #require(host.strip)
		#expect(abs(shown.frame.minY - host.window.frame.minY) < 0.5)
		#expect(host.requests == [.open])
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

	@Test func deleteKeepsTheCardOrderUntilTheLiveFadeCompletes() async {
		let host = StripHost(width: 1000)
		defer { host.close() }
		await host.settle()
		let deleted = host.model.clips[0].id
		let order = host.model.clips.map(\.id)
		var fadeCompleted = false
		let live = Animator.live { false }
		host.model.animator = Animator { event, change, completion in
			live.run(event, change) {
				if event == .delete { fadeCompleted = true }
				completion()
			}
		}
		await host.model.deleteSelected()
		await host.settle(80)
		#expect(!fadeCompleted)
		#expect(host.model.clips.contains { $0.id == deleted })
		#expect(host.model.removingIDs.contains(deleted))
		#expect(host.model.clips.map(\.id) == order)
		await host.settle(500)
		#expect(fadeCompleted)
		#expect(!host.model.clips.contains { $0.id == deleted })
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
