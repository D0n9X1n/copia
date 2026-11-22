import AppKit
import SwiftUI
import CopiaApp
import CopiaUI

/// The ScreenCaptureKit checks: ⌘Y to first presented frame, scroll smoothness and motion settle.
/// Only the fixture panel and generated wallpaper are recorded; the watcher polls a private pasteboard.
@MainActor
final class RecordedRun {
	// Crop geometry in points, top-left origin, from StripView's layout.
	static let rowTop = Int(Theme.topBarHeight)
	static let cardTop = Int(Theme.topBarHeight + (Theme.rowHeight - Theme.cardSize.height) / 2)
	static let cardBottom = cardTop + Int(Theme.cardSize.height)
	/// Card rows above the toast.
	static let bodyRows = cardTop..<(cardTop + 190)
	/// The lens ring's top edge, between the top bar and the card.
	static let ringRows = (cardTop - 7)..<cardTop
	static let slot = Int(Theme.cardSize.width + Theme.cardGap)
	static let panelHeight = Int(Theme.panelHeight)
	static func slotX(_ i: Int) -> Int { Int(Theme.rowPadding) + i * slot }
	static var firstCardColumns: Range<Int> { (slotX(0) + 6)..<(slotX(0) + Int(Theme.cardSize.width) - 6) }
	static let maxWidth = 1_000

	let controller: AppController
	let recorder: Recorder
	let wallpaper: Wallpaper
	let refresh: Double
	private let originalRoot: AnyView
	private let originalAnimator: Animator
	private var starts: [(event: MotionEvent, time: Double)] = []
	private var reduced = false
	private(set) var motionInterruptions: [String: [Int]] = [:]
	private var motionRound = 1

	init(controller: AppController, recorder: Recorder, wallpaper: Wallpaper, refresh: Double) {
		self.controller = controller
		self.recorder = recorder
		self.wallpaper = wallpaper
		self.refresh = refresh
		originalRoot = controller.panel.host.rootView
		originalAnimator = controller.model.animator
	}

	/// Pins the panel to its screen, puts the wallpaper behind it and starts recording the two windows.
	static func start(_ controller: AppController) async throws -> RecordedRun {
		let panel = controller.panel
		let screen = NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main!
		if controller.visibleFrameOverride == nil { controller.visibleFrameOverride = screen.visibleFrame }
		let fps = max(screen.maximumFramesPerSecond, 60)
		controller.toggleHistory()
		try? await Task.sleep(for: .milliseconds(600))
		let wallpaper = Wallpaper(behind: panel)
		wallpaper.show()
		panel.ignoresMouseEvents = true
		let recorder = Recorder(width: min(Int(panel.frame.width), maxWidth), height: Int(panel.frame.height))
		let run = RecordedRun(controller: controller, recorder: recorder, wallpaper: wallpaper, refresh: 1 / Double(fps))
		let live = Animator.live { [unowned run] in run.reduced }
		controller.model.animator = Animator { [unowned run] event, change, completion in
			run.starts.append((event, HostClock.now))
			live.run(event, change, completion)
		}
		do {
			try await recorder.start(panel: panel, wallpaper: wallpaper.window)
		} catch {
			await run.finish()
			throw error
		}
		await run.hide()
		return run
	}

	func finish() async {
		await hide()
		await recorder.stop()
		wallpaper.hide()
		controller.panel.ignoresMouseEvents = false
		controller.panel.host.rootView = originalRoot
		controller.model.animator = originalAnimator
	}

	// MARK: ⌘Y to first presented frame

	/// Milliseconds from the toggle to the first presented frame that shows the first card (2,000 when none does).
	func latencies(_ count: Int) async -> [Double] {
		var out: [Double] = []
		for _ in 0..<count {
			await prepare(reduced: false)
			recorder.begin(.planes)
			let start = HostClock.now
			controller.toggleHistory()
			try? await Task.sleep(for: .milliseconds(700))
			let shown = Self.firstCardShown(recorder.endPlanes(), after: start)
			out.append(shown.map { ($0 - start) * 1_000 } ?? 2_000)
		}
		await hide()
		return out
	}

	/// The first frame after `start` in which the first card's top 8+ rows match the settled open frame.
	static func firstCardShown(_ frames: [Recorder.Frame], after start: Double) -> Double? {
		guard let final = frames.last?.luma else { return nil }
		let header = cardTop..<(cardTop + 16)
		return frames.first { frame in
			frame.time > start && FrameAnalysis.locate(rows: header, columns: firstCardColumns, of: final, in: frame.luma,
				axis: .vertical, shifts: 0...(panelHeight - header.lowerBound - 8), minOverlap: 8, maxCost: 10, step: 2) != nil
		}?.time
	}

	struct PointerSample {
		let dispatch: Double?
		let commit: Double
		let presented: Double?
	}

	nonisolated static let pointerSlots = [1, 0, 2, 1, 0]

	nonisolated static func pointerSnapPasses(_ samples: [PointerSample]) -> Bool {
		guard samples.count == pointerSlots.count, samples.allSatisfy({ $0.dispatch != nil }) else { return false }
		let presented = samples.compactMap(\.presented).sorted()
		return presented.count == samples.count && presented[presented.count / 2] <= 0.1
	}

	func pointerSelections() async -> [PointerSample] {
		await prepare(reduced: false)
		let panel = controller.panel, model = controller.model
		controller.toggleHistory()
		try? await Task.sleep(for: .milliseconds(700))
		var samples: [PointerSample] = []
		for slot in Self.pointerSlots {
			let left = Self.slotX(slot)
			guard left + Int(Theme.cardSize.width) <= recorder.width, model.visibleClips.indices.contains(slot) else { continue }
			let expected = model.visibleClips[slot].id
			let point = CGPoint(x: CGFloat(left) + Theme.cardSize.width / 2,
				y: Theme.panelHeight - CGFloat(Self.cardTop) - Theme.cardSize.height / 2)
			func event(_ type: NSEvent.EventType) -> NSEvent? {
				NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
					windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
			}
			guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { continue }
			recorder.begin(.planes)
			try? await Task.sleep(for: .milliseconds(180))
			let start = HostClock.now
			panel.sendEvent(down)
			let dispatch = model.selectedID == expected ? HostClock.now - start : nil
			panel.host.layoutSubtreeIfNeeded()
			CATransaction.flush()
			let commit = HostClock.now - start
			panel.sendEvent(up)
			try? await Task.sleep(for: .milliseconds(650))
			let columns = (left + 42)..<(left + Int(Theme.cardSize.width) - 42)
			let shown = Self.firstRingFrame(recorder.endPlanes(), after: start, rows: Self.ringRows, columns: columns)
			samples.append(PointerSample(dispatch: dispatch, commit: commit, presented: shown.map { $0 - start }))
		}
		await hide()
		return samples
	}

	static func firstRingFrame(_ frames: [Recorder.Frame], after start: Double, rows: Range<Int>, columns: Range<Int>) -> Double? {
		guard let before = frames.last(where: { $0.time <= start })?.luma, let final = frames.last?.luma else { return nil }
		let contrast = before.meanDifference(final, rows: rows, columns: columns)
		guard contrast > 4 else { return nil }
		return frames.first { $0.time > start && $0.luma.meanDifference(final, rows: rows, columns: columns) < contrast / 2 }?.time
	}

	// MARK: Scroll

	/// Keeps the recorded distance and frame count even when the fixture was interrupted.
	func scroll(velocity: Double, seconds: Double) async -> Smoothness.Trial {
		await prepare(reduced: false)
		let panel = controller.panel, model = controller.model
		let closeCount = model.closeCount
		controller.toggleHistory()
		try? await Task.sleep(for: .milliseconds(700))
		func active() -> Bool { panel.isVisible && panel.isKeyWindow && model.cardsMounted && !model.isClosing && model.closeCount == closeCount }
		guard let scrollView = Bench.scrollView(in: panel.host), let view = panel.contentView, active() else {
			let reason: Smoothness.InvalidTrial = active() ? .missingRow : .panelChanged
			await hide()
			return .init(result: nil, reason: reason, distance: nil, elapsed: nil, captured: 0)
		}
		recorder.begin(.hashes(rows: Self.cardTop..<Self.cardBottom))
		let driver = ScrollDriver(scrollView: scrollView, velocity: velocity, seconds: seconds)
		driver.start(on: view)
		for _ in 0..<Int((seconds + 2) * 50) {
			if driver.finished || !active() { break }
			try? await Task.sleep(for: .milliseconds(20))
		}
		driver.stop()
		try? await Task.sleep(for: .milliseconds(150))
		let hashes = recorder.endHashes()
		let distance = abs(scrollView.contentView.bounds.minX - driver.initialOffset)
		let samePresentation = active() && scrollView === Bench.scrollView(in: panel.host)
		await hide()
		return Smoothness.trial(frames: hashes, first: driver.firstTick, last: driver.lastTick, finished: driver.finished,
			samePresentation: samePresentation, distance: distance, velocity: velocity, seconds: seconds, refresh: refresh)
	}

	// MARK: Motion settle

	/// Settle times per motion ("open", "open.reduced", …), one sample per round; nil when it never settled.
	func motion(rounds: Int) async -> [String: [Settle?]] {
		var samples: [String: [Settle?]] = [:]
		let model = controller.model
		let w = recorder.width
		for reduced in [false, true] {
			let suffix = reduced ? ".reduced" : ""
			for round in 0..<rounds {
				motionRound = round + 1
				await prepare(reduced: reduced)
				let open = await trial(.open, seconds: 0.9) { self.controller.toggleHistory() }
				samples["open" + suffix, default: []].append(settle(open) { frames, final in
					reduced ? Self.distanceErrors(frames, final: final, rows: Self.rowTop..<Self.panelHeight, columns: 0..<w)
						: Self.shiftErrors(frames, final: final, rows: Self.cardTop..<Self.cardBottom, columns: Self.firstCardColumns,
							axis: .vertical, shifts: -10...Self.panelHeight, minOverlap: 8, step: 2, travel: Theme.panelHeight)
				})
				let lens = await trial(.lens, seconds: 0.7) { model.move(1) }
				samples["lens" + suffix, default: []].append(settle(lens) { frames, final in
					Self.lensErrors(frames, final: final, width: w)
				})
				let delete = await trial(.delete, seconds: 1.0) { await model.deleteSelected() }
				let deleted = settle(delete, requireProgress: true) { frames, final in
					reduced ? Self.distanceErrors(frames, final: final, rows: Self.bodyRows, columns: Self.slotX(1)..<w)
						: Self.shiftErrors(frames, final: final, rows: Self.bodyRows, columns: Self.slotX(1)..<w,
							axis: .horizontal, shifts: -8...240, minOverlap: 300, step: 6, travel: Double(Self.slot))
				}
				let fade = delete.trigger.flatMap { trigger in
					starts.first { $0.event == .reflow && $0.time >= trigger }.map { reflow in
						Self.outgoingFadePresented(delete.frames, after: trigger, beforeReflow: reflow.time,
							rows: Self.bodyRows, columns: (Self.slotX(1) + 12)..<(Self.slotX(1) + Int(Theme.cardSize.width) - 12))
					}
				} ?? false
				samples["delete" + suffix, default: []].append(fade ? deleted : nil)
				let undo = await trial(.undo, seconds: 0.8) { await model.undo() }
				samples["undo" + suffix, default: []].append(settle(undo, requireProgress: true) { frames, final in
					let fade = Self.distanceErrors(frames, final: final, rows: Self.bodyRows,
						columns: Self.slotX(1)..<(reduced ? w : Self.slotX(1) + Int(Theme.cardSize.width)))
					guard !reduced else { return fade }
					let shift = Self.shiftErrors(frames, final: final, rows: Self.bodyRows, columns: Self.slotX(2)..<w,
						axis: .horizontal, shifts: -240...8, minOverlap: 300, step: 6, travel: Double(Self.slot))
					return zip(shift, fade).map { max($0, $1) }
				})
				let close = await trial(.close, seconds: 0.6) { self.controller.toggleHistory() }
				samples["close" + suffix, default: []].append(settle(close) { frames, final in
					Self.distanceErrors(frames, final: final, rows: Self.rowTop..<Self.panelHeight, columns: 0..<w)
				})
			}
		}
		await hide()
		return samples
	}

	static func outgoingFadePresented(_ frames: [Recorder.Frame], after trigger: Double, beforeReflow: Double,
		rows: Range<Int>, columns: Range<Int>) -> Bool {
		guard let initial = frames.last(where: { $0.time < trigger })?.luma else { return false }
		let changes = frames.filter { $0.time >= trigger && $0.time < beforeReflow }.map {
			$0.luma.meanDifference(initial, rows: rows, columns: columns)
		}
		guard let peak = changes.max(), peak > 4 else { return false }
		// A held start, a snap to an empty slot, and later moving neighbours are not an outgoing fade.
		var previous: Double?
		for change in changes where change > peak * 0.05 && change < peak * 0.95 {
			if let previous, change > previous + peak * 0.05 { return true }
			previous = min(previous ?? change, change)
		}
		return false
	}

	/// Error = how far the content still is from its final position, as a fraction of `travel`; 1 when it is not found.
	static func shiftErrors(_ frames: [Luma], final: Luma, rows: Range<Int>, columns: Range<Int>, axis: FrameAnalysis.Axis,
		shifts: ClosedRange<Int>, minOverlap: Int, step: Int, travel: Double) -> [Double] {
		frames.map { frame in
			guard let best = FrameAnalysis.bestShift(rows: rows, columns: columns, of: final, in: frame, axis: axis,
				shifts: shifts, minOverlap: minOverlap, step: step), best.cost <= 12 else { return 1 }
			// Half a point for rounding: a frame only counts as settled when the true offset is surely within 1%.
			return min(1, (Double(abs(best.shift)) + 0.5) / travel)
		}
	}

	/// Error = luma distance to the final frame as a fraction of the largest distance in the trial (fades, crossfades).
	static func distanceErrors(_ frames: [Luma], final: Luma, rows: Range<Int>, columns: Range<Int>) -> [Double] {
		let distances = frames.map { $0.meanDifference(final, rows: rows, columns: columns) }
		let peak = distances.max() ?? 0
		return peak > 0 ? distances.map { $0 / peak } : distances
	}

	/// Error = the lens ring's distance from its final x, as a fraction of its travel (card 0 to card 1).
	static func lensErrors(_ frames: [Luma], final: Luma, width: Int) -> [Double] {
		guard let start = frames.first else { return [] }
		// The background has no ring: the final frame left of the gap between the cards, the start frame right of it.
		let split = slotX(1) - Int(Theme.cardGap) / 2
		var background = start
		for y in ringRows { for x in 0..<split { background[x, y] = final[x, y] } }
		func ring(_ frame: Luma) -> Double? {
			FrameAnalysis.centroid(frame, background: background, rows: ringRows, columns: 0..<width, threshold: 24)
		}
		guard let from = ring(start), let to = ring(final), abs(to - from) > 1 else { return frames.map { _ in 1 } }
		return frames.map { frame in ring(frame).map { min(1, abs($0 - to) / abs(to - from)) } ?? 1 }
	}

	// MARK: Trials

	private func prepare(reduced: Bool) async {
		await hide()
		install(reduced: reduced)
		if let first = controller.model.clips.first?.id { controller.model.select(first) }
	}

	/// A fresh root (so the row starts at the leading edge) with Reduce Motion forced on or off.
	private func install(reduced: Bool) {
		self.reduced = reduced
		controller.panel.host.rootView = AnyView(originalRoot.environment(\.copiaOverrides, CopiaOverrides(reduceMotion: reduced)))
	}

	private func hide() async {
		if controller.panel.isVisible, controller.model.cardsMounted { controller.toggleHistory() }
		for _ in 0..<100 where controller.panel.isVisible { try? await Task.sleep(for: .milliseconds(10)) }
		try? await Task.sleep(for: .milliseconds(150))
	}

	/// Records frames around `action`; the trigger is when the Animator started `event`.
	func trial(_ event: MotionEvent, seconds: Double, _ action: () async -> Void) async -> (frames: [Recorder.Frame], trigger: Double?) {
		let model = controller.model, panel = controller.panel
		let key = "\(event)" + (reduced ? ".reduced" : "")
		func ready(open: Bool) -> Bool {
			panel.isVisible == open && model.cardsMounted == open && !model.isClosing && (!open || panel.isKeyWindow)
		}
		let closeCount = model.closeCount
		guard ready(open: event != .open) else {
			motionInterruptions[key, default: []].append(motionRound)
			return ([], nil)
		}
		recorder.begin(.planes)
		let from = HostClock.now
		await action()
		try? await Task.sleep(for: .seconds(seconds))
		let frames = recorder.endPlanes()
		guard ready(open: event != .close), model.closeCount == closeCount + (event == .close ? 1 : 0) else {
			motionInterruptions[key, default: []].append(motionRound)
			return (frames, nil)
		}
		return (frames, starts.first { $0.event == event && $0.time >= from }?.time)
	}

	/// Settle time from the motion's first visible change (see `FrameAnalysis.motionStart`), and from the trigger.
	private func settle(_ trial: (frames: [Recorder.Frame], trigger: Double?), requireProgress: Bool = false, errors: ([Luma], Luma) -> [Double]) -> Settle? {
		guard let trigger = trial.trigger, let final = trial.frames.last?.luma else { return nil }
		let times = trial.frames.map(\.time)
		let lumas = trial.frames.map(\.luma)
		let before = trial.frames.last { $0.time < trigger }?.luma ?? lumas[0]
		// Below the top bar, where the search caret blinks.
		let changed = lumas.map { $0.changedPixels(before, rows: Self.rowTop..<Self.panelHeight, columns: 0..<$0.width, threshold: 8) >= 8 }
		let start = FrameAnalysis.motionStart(times: times, changed: changed, trigger: trigger, refresh: refresh)
		let errors = errors(lumas, final)
		guard !requireProgress || FrameAnalysis.showsProgress(times: times, changed: changed, errors: errors, after: trigger) else { return nil }
		guard let fromStart = FrameAnalysis.settleTime(times: times, errors: errors, trigger: start, tolerance: SettleBudget.tolerance)
		else { return nil }
		return Settle(seconds: max(0, fromStart), fromTrigger: fromStart + start - trigger)
	}
}

struct Settle {
	/// From one refresh before the first visible change to the first frame that stays within 1%.
	let seconds: Double
	/// From the Animator call: adds the compositor's latency to the screen.
	let fromTrigger: Double
}

/// Scrolls the row at a constant velocity, one step per display refresh. Owned by the bench, not Copia.
@MainActor
final class ScrollDriver: NSObject {
	let scrollView: NSScrollView
	let velocity: Double
	let seconds: Double
	private(set) var initialOffset: CGFloat = 0
	private var requestedDistance = 0
	private(set) var firstTick: Double?
	private(set) var lastTick: Double?
	private(set) var finished = false
	private var link: CADisplayLink?

	init(scrollView: NSScrollView, velocity: Double, seconds: Double) {
		self.scrollView = scrollView
		self.velocity = velocity
		self.seconds = seconds
	}

	func start(on view: NSView) {
		initialOffset = scrollView.contentView.bounds.minX
		let link = view.displayLink(target: self, selector: #selector(tick(_:)))
		if let screen = view.window?.screen {
			let hz = Float(screen.maximumFramesPerSecond)
			if hz > 0 { link.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz) }
		}
		link.add(to: .main, forMode: .common)
		self.link = link
	}

	func stop() {
		link?.invalidate()
		link = nil
	}

	@objc func tick(_ link: CADisplayLink) {
		let time = link.targetTimestamp
		let start = firstTick ?? time
		firstTick = start
		lastTick = time
		let distance = Int((velocity * min(seconds, time - start)).rounded())
		let delta = distance - requestedDistance
		requestedDistance = distance
		if delta != 0, let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
			wheelCount: 2, wheel1: 0, wheel2: Int32(clamping: -delta), wheel3: 0), let event = NSEvent(cgEvent: cg) {
			// Deliver only to the fixture scroll view, never to the desktop event stream.
			scrollView.scrollWheel(with: event)
		}
		if time - start >= seconds {
			link.invalidate()
			self.link = nil
			finished = true
		}
	}
}
