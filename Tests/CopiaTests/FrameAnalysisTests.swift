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

	@Test func settleTimeRunsFromTheTriggerToTheFrameThatStaysSettled() {
		let times = [0.0, 0.010, 0.020, 0.030, 0.040, 0.050]
		let errors = [1.0, 0.5, 0.005, 0.02, 0.0, 0.001]
		let settle = FrameAnalysis.settleTime(times: times, errors: errors, trigger: 0.005, tolerance: 0.01)
		#expect(abs((settle ?? -1) - 0.035) < 1e-12)
	}

	@Test func aChangeThatNeverSettlesOrNeverShowsHasNoSettleTime() {
		#expect(FrameAnalysis.settleTime(times: [0, 0.01], errors: [1, 0.2], trigger: 0, tolerance: 0.01) == nil)
		#expect(FrameAnalysis.settleTime(times: [0, 0.01], errors: [0, 0], trigger: 0, tolerance: 0.01) == nil)
		#expect(FrameAnalysis.settleTime(times: [], errors: [], trigger: 0, tolerance: 0.01) == nil)
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
