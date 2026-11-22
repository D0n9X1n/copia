import Testing
@testable import CopiaBench

@Suite struct FrameAnalysisTests {
	/// A pattern with no two rows or columns alike, so a shift has exactly one match.
	static func pattern(width: Int, height: Int, seed: UInt64) -> Luma {
		var state = seed
		var pixels: [UInt8] = []
		for _ in 0..<(width * height) {
			state = state &* 6364136223846793005 &+ 1442695040888963407
			pixels.append(UInt8(truncatingIfNeeded: state >> 56))
		}
		return Luma(width: width, height: height, pixels: pixels)
	}

	/// `reference` moved by `shift` along `axis` over `wallpaper`.
	static func moved(_ reference: Luma, by shift: Int, axis: FrameAnalysis.Axis, over wallpaper: Luma) -> Luma {
		var frame = wallpaper
		for y in 0..<reference.height {
			for x in 0..<reference.width {
				let (sx, sy) = axis == .vertical ? (x, y - shift) : (x - shift, y)
				if sx >= 0, sx < reference.width, sy >= 0, sy < reference.height { frame[x, y] = reference[sx, sy] }
			}
		}
		return frame
	}

	static let reference = pattern(width: 90, height: 70, seed: 1)
	static let wallpaper = pattern(width: 90, height: 70, seed: 2)

	@Test func pointerSnapNeedsEveryPressAndAtMost100msMedianToTheVisibleTarget() {
		func sample(_ ms: Double?) -> RecordedRun.PointerSample {
			.init(dispatch: 0.002, commit: 0.008, presented: ms.map { $0 / 1_000 })
		}
		#expect(RecordedRun.pointerSnapPasses([20, 25, 35, 90, 150].map(sample)))
		#expect(!RecordedRun.pointerSnapPasses([20, 25, 101, 120, 150].map(sample)))
		#expect(!RecordedRun.pointerSnapPasses([20, 25, nil, 50, 80].map(sample)))
		#expect(!RecordedRun.pointerSnapPasses([sample(20)]))
		#expect(!RecordedRun.pointerSnapPasses([.init(dispatch: nil, commit: 0.008, presented: 0.03)] + [20, 25, 30, 35].map(sample)))
	}

	@Test @MainActor func pointerTimingRequiresChangedPixelsOnTheClickedRing() {
		let before = Luma(width: 3, height: 2, fill: 30)
		var other = before, half = before, final = before
		other[0, 0] = 220; half[2, 0] = 150; final[2, 0] = 220
		let frames = [Recorder.Frame(time: 1, luma: before), .init(time: 2, luma: other),
			.init(time: 3, luma: half), .init(time: 4, luma: final)]
		#expect(RecordedRun.firstRingFrame(frames, after: 1.5, rows: 0..<1, columns: 2..<3) == 3)
		#expect(RecordedRun.firstRingFrame(frames, after: 1.5, rows: 1..<2, columns: 2..<3) == nil)
		#expect(RecordedRun.firstRingFrame(frames, after: 0.5, rows: 0..<1, columns: 2..<3) == nil)
	}

	@Test func locatesAVerticalShift() {
		let frame = Self.moved(Self.reference, by: 23, axis: .vertical, over: Self.wallpaper)
		#expect(FrameAnalysis.locate(rows: 0..<70, columns: 0..<90, of: Self.reference, in: frame, axis: .vertical,
			shifts: 0...69, minOverlap: 8, maxCost: 4) == 23)
	}

	@Test func locatesAHorizontalShiftEitherWay() {
		for shift in [-17, 0, 31] {
			let frame = Self.moved(Self.reference, by: shift, axis: .horizontal, over: Self.wallpaper)
			#expect(FrameAnalysis.locate(rows: 10..<60, columns: 0..<90, of: Self.reference, in: frame, axis: .horizontal,
				shifts: -40...40, minOverlap: 20, maxCost: 4) == shift)
		}
	}

	@Test func findsNothingOnceTheTemplateLeavesTheFrame() {
		#expect(FrameAnalysis.locate(rows: 0..<70, columns: 0..<90, of: Self.reference, in: Self.wallpaper, axis: .vertical,
			shifts: 0...69, minOverlap: 8, maxCost: 4) == nil)
		// Only 5 rows still visible: below the minimum overlap.
		let frame = Self.moved(Self.reference, by: 65, axis: .vertical, over: Self.wallpaper)
		#expect(FrameAnalysis.locate(rows: 0..<70, columns: 0..<90, of: Self.reference, in: frame, axis: .vertical,
			shifts: 0...69, minOverlap: 8, maxCost: 4) == nil)
	}

	@Test func shiftsThatPushTheWholeTemplateOutOfTheFrameAreSkipped() {
		// Rows 40..<70 shifted by 60 or more land entirely below a 70-row frame.
		let frame = Self.moved(Self.reference, by: 12, axis: .vertical, over: Self.wallpaper)
		#expect(FrameAnalysis.locate(rows: 40..<70, columns: 0..<90, of: Self.reference, in: frame, axis: .vertical,
			shifts: -80...80, minOverlap: 8, maxCost: 4) == 12)
	}

	@Test func settleTimeRunsFromTheTriggerToTheFrameThatStaysSettled() {
		let times = [0.0, 0.010, 0.020, 0.030, 0.040, 0.050]
		let errors = [1.0, 0.5, 0.005, 0.02, 0.0, 0.001]
		let settle = FrameAnalysis.settleTime(times: times, errors: errors, trigger: 0.005, tolerance: 0.01)
		#expect(abs((settle ?? -1) - 0.035) < 1e-12)
	}

	@Test func aMovingRowMustShowChangedIntermediatePixelsAfterTheTrigger() {
		let times = [0.0, 0.1, 0.2, 0.3]
		let changed = [false, false, true, true]
		#expect(FrameAnalysis.showsProgress(times: times, changed: changed, errors: [1, 0.7, 0.3, 0], after: 0.05))
		#expect(!FrameAnalysis.showsProgress(times: times, changed: changed, errors: [0.67, 0.67, 1, 0], after: 0.05))
		#expect(!FrameAnalysis.showsProgress(times: times, changed: changed, errors: [1, 0.999, 0.001, 0], after: 0.05))
		#expect(!FrameAnalysis.showsProgress(times: times, changed: changed, errors: [0.5, 1, 0, 0], after: 0.05))
	}

	@Test @MainActor func outgoingFadeNeedsDistinctPixelsInsideTheDeletedCardBeforeReflow() {
		let original = Luma(width: 12, height: 5, fill: 200)
		func frame(_ t: Double, _ left: UInt8, _ right: UInt8) -> Recorder.Frame {
			var p = original
			for y in 0..<5 { for x in 0..<12 { p[x,y] = x < 6 ? left : right } }
			return .init(time: t, luma: p)
		}
		func fades(_ f: [Recorder.Frame]) -> Bool {
			RecordedRun.outgoingFadePresented(f, after: 1.0, beforeReflow: 1.25, rows: 0..<5, columns: 0..<6)
		}
		let before = frame(0.95, 200, 200), stale = frame(1.01, 200, 200), empty = frame(1.20, 40, 200)
		#expect(fades([before, stale, frame(1.08, 150, 200), frame(1.14, 80, 200), empty]))
		#expect(!fades([before, stale, empty, frame(1.30, 130, 150)]))
		#expect(!fades([before, frame(1.08, 200, 120), frame(1.14, 200, 60), empty]))
		#expect(!fades([before, frame(1.06, 80, 200), frame(1.14, 80, 200), empty]))
		#expect(!fades([stale, empty]))
	}

	@Test func aChangeThatNeverSettlesOrNeverShowsHasNoSettleTime() {
		#expect(FrameAnalysis.settleTime(times: [0, 0.01], errors: [1, 0.2], trigger: 0, tolerance: 0.01) == nil)
		#expect(FrameAnalysis.settleTime(times: [0, 0.01], errors: [0, 0], trigger: 0, tolerance: 0.01) == nil)
		#expect(FrameAnalysis.settleTime(times: [], errors: [], trigger: 0, tolerance: 0.01) == nil)
	}

	@Test func motionStartsOneRefreshBeforeItsFirstVisibleChangeButNeverBeforeTheTrigger() {
		let times = [0.0, 0.050, 0.0667, 0.0833]
		#expect(abs(FrameAnalysis.motionStart(times: times, changed: [false, false, true, true], trigger: 0.01, refresh: 1.0 / 60)
			- (0.0667 - 1.0 / 60)) < 1e-9)
		#expect(FrameAnalysis.motionStart(times: times, changed: [false, true, true, true], trigger: 0.045, refresh: 1.0 / 60) == 0.045)
		#expect(FrameAnalysis.motionStart(times: times, changed: [false, false, false, false], trigger: 0.01, refresh: 1.0 / 60) == 0.01)
		// A change before the trigger is not this motion's.
		#expect(FrameAnalysis.motionStart(times: times, changed: [true, false, false, true], trigger: 0.01, refresh: 1.0 / 60)
			== 0.0833 - 1.0 / 60)
	}

	@Test func changedPixelsCountsOnlyClearDifferencesInTheRegion() {
		let a = Luma(width: 10, height: 10, fill: 100)
		var b = a
		b[1, 1] = 120
		b[2, 2] = 104 // below the threshold
		b[9, 9] = 200 // outside the region
		#expect(a.changedPixels(b, rows: 0..<5, columns: 0..<5, threshold: 8) == 1)
	}

	@Test func streamedCropHashMatchesEveryPixelOfTheLumaPlane() {
		let raw = (0..<(12 * 9 * 4)).map { UInt8(truncatingIfNeeded: $0 &* 73) }
		for x in [0, 1, 3] {
			raw.withUnsafeBytes { bytes in
				let plane = Luma(bgra: bytes.baseAddress!, bytesPerRow: 48, x: x, y: 2, width: 9, height: 5)
				#expect(Luma.hash(bgra: bytes.baseAddress!, bytesPerRow: 48, x: x, y: 2, width: 9, height: 5) == plane.hash())
			}
		}
	}

	@Test func centroidFindsTheColumnsThatDifferFromTheBackground() {
		let background = Luma(width: 100, height: 10, fill: 128)
		var frame = background
		for y in 2..<5 { for x in 40..<60 { frame[x, y] = 250 } }
		frame[90, 8] = 200 // outside the band
		#expect(FrameAnalysis.centroid(frame, background: background, rows: 0..<6, columns: 0..<100, threshold: 24) == 49.5)
		#expect(FrameAnalysis.centroid(background, background: background, rows: 0..<6, columns: 0..<100, threshold: 24) == nil)
	}

	@Test func lumaComesFromABGRACrop() {
		// 3×1 BGRA: white, black, pure red; plus a fourth pixel outside the crop.
		let bytes: [UInt8] = [255, 255, 255, 255, 0, 0, 0, 255, 0, 0, 255, 255, 9, 9, 9, 255]
		let luma = bytes.withUnsafeBytes { Luma(bgra: $0.baseAddress!, bytesPerRow: 16, x: 0, y: 0, width: 3, height: 1) }
		#expect(luma.pixels[0] >= 254)
		#expect(luma.pixels[1] == 0)
		#expect(luma.pixels[2] > 40 && luma.pixels[2] < 70)
	}

	@Test func regionDifferenceLooksOnlyInsideTheRegion() {
		let a = Luma(width: 4, height: 4, fill: 10)
		var b = a
		b[0, 0] = 110 // outside rows 2..<4
		b[3, 3] = 50
		#expect(a.meanDifference(b, rows: 2..<4, columns: 0..<4) == 5)
		#expect(a.meanDifference(b, rows: 0..<1, columns: 0..<1) == 100)
	}

	@Test func bestShiftReportsItsCostEvenWhenItIsHigh() {
		let match = FrameAnalysis.bestShift(rows: 0..<70, columns: 0..<90, of: Self.reference, in: Self.wallpaper,
			axis: .vertical, shifts: 0...69, minOverlap: 8)
		#expect(match != nil)
		#expect((match?.cost ?? 0) > 4)
		let frame = Self.moved(Self.reference, by: 9, axis: .vertical, over: Self.wallpaper)
		let found = FrameAnalysis.bestShift(rows: 0..<70, columns: 0..<90, of: Self.reference, in: frame,
			axis: .vertical, shifts: 0...69, minOverlap: 8)
		#expect(found?.shift == 9)
		#expect(found?.cost == 0)
	}

	@Test func identicalCropsHashAlikeAndAOnePixelChangeDoesNot() {
		var other = Self.reference
		#expect(other.hash() == Self.reference.hash())
		other[45, 35] &+= 1
		#expect(other.hash() != Self.reference.hash())
		#expect(Self.reference.meanDifference(Self.reference) == 0)
		#expect(Luma(width: 2, height: 2, fill: 10).meanDifference(Luma(width: 2, height: 2, fill: 30)) == 20)
	}
}

@Suite struct SmoothnessTests {
	static let refresh = 1.0 / 120

	static func frames(_ count: Int, every interval: Double = refresh, hash: (Int) -> UInt64 = { UInt64($0) }) -> [Smoothness.Frame] {
		(0..<count).map { Smoothness.Frame(time: Double($0) * interval, hash: hash($0)) }
	}

	@Test @MainActor func recorderTakesNativeDisplayFramesWithoutASecondRateLimiter() {
		let config = Recorder(width: 800, height: 316).configuration(sourceRect: .init(x: 0, y: 0, width: 800, height: 316))
		#expect(config.minimumFrameInterval.value == 0 && config.minimumFrameInterval.isValid)
		#expect(!config.showsCursor && config.width == 800 && config.height == 316)
	}

	@Test func aFullClockWindowCannotPassWithShortOrMissingTravel() {
		#expect(Smoothness.travelIsComplete(20_000, velocity: 4_000, seconds: 5, refresh: 1/120))
		#expect(!Smoothness.travelIsComplete(19_900, velocity: 4_000, seconds: 5, refresh: 1/120))
		#expect(!Smoothness.travelIsComplete(0, velocity: 4_000, seconds: 5, refresh: 1/120))
		#expect(Smoothness.travelIsComplete(0, velocity: 0, seconds: 1.5, refresh: 1/120))
		#expect(!Smoothness.travelIsComplete(10, velocity: 0, seconds: 1.5, refresh: 1/120))
	}

	@Test func aScrollReportsWhyItCouldNotBeScoredAndKeepsTheActualTravel() {
		let frames = Self.frames(601)
		func run(_ active: Bool = true, finished: Bool = true, last: Double = 5,
			distance: Double = 20_000, observed: [Smoothness.Frame]? = nil, speed: Double = 4_000) -> Smoothness.Trial {
			Smoothness.trial(frames: observed ?? frames, first: 0, last: last, finished: finished, samePresentation: active,
				distance: distance, velocity: speed, seconds: 5, refresh: Self.refresh)
		}
		let interrupted = run(false, finished: false, last: 0.9, distance: 3600, observed: Self.frames(102))
		#expect(interrupted.result == nil && interrupted.reason == .panelChanged)
		#expect(interrupted.distance == 3600 && interrupted.elapsed == 0.9 && interrupted.captured == 102)
		#expect(run(finished: false).reason == .driverIncomplete)
		#expect(run(last: 3).reason == .incompleteWindow)
		#expect(run(distance: 19_000).reason == .incompleteTravel)
		#expect(run(observed: []).reason == .noFrames)
		#expect(run(distance: 0, observed: Self.frames(2), speed: 0).reason == .noFrames)
		let emptyControl = run(distance: 0, observed: [], speed: 0)
		#expect(emptyControl.result == nil && emptyControl.reason == .noFrames)
		#expect(run().result?.passes == true && run().reason == nil)
		let frozen = run(distance: 0, observed: Self.frames(601, hash: { _ in 7 }), speed: 0)
		#expect(frozen.reason == nil && frozen.result?.passes == false)
	}

	@Test func interruptedScrollCannotPassWithAnEarlyLastTick() {
		#expect(Smoothness.window(first: 1, last: 3, duration: 5, refresh: Self.refresh) == nil)
		#expect(Smoothness.window(first: 1, last: 6, duration: 5, refresh: Self.refresh) == (1 + 3 * Self.refresh)...6)
	}

	@Test func aRowThatMovesEveryRefreshPasses() {
		let result = Smoothness.evaluate(Self.frames(600), window: 0.02...4.9, refresh: Self.refresh)
		#expect(result.freshFraction == 1)
		#expect(result.onTimeFraction == 1)
		#expect(result.passes)
	}

	@Test func aFrozenRowFails() {
		let result = Smoothness.evaluate(Self.frames(180, hash: { _ in 7 }), window: 0.02...1.4, refresh: Self.refresh)
		#expect(result.freshFraction == 0)
		#expect(!result.passes)
	}

	@Test func noFramesAtAllFails() {
		let result = Smoothness.evaluate([], window: 0...1.5, refresh: Self.refresh)
		#expect(result.presented == 0)
		#expect(!result.passes)
	}

	@Test func halfRateFailsOnIntervalsEvenWithNewContent() {
		let result = Smoothness.evaluate(Self.frames(300, every: 2 * Self.refresh), window: 0.02...4.9, refresh: Self.refresh)
		#expect(result.freshFraction == 1)
		#expect(!result.passes)
	}

	@Test func aFewStallsStayWithinBudget() {
		// 2% of frames repeat the previous content, and those intervals are long.
		var frames: [Smoothness.Frame] = []
		var time = 0.0
		for i in 0..<600 {
			let stall = i % 50 == 25
			time += stall ? 2 * Self.refresh : Self.refresh
			frames.append(Smoothness.Frame(time: time, hash: stall ? frames.last!.hash : UInt64(i)))
		}
		let result = Smoothness.evaluate(frames, window: 0.03...time, refresh: Self.refresh)
		#expect(result.freshFraction > 0.95 && result.freshFraction < 1)
		#expect(result.passes)
	}
}
