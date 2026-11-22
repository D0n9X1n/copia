import Foundation

/// One 8-bit luma plane, one byte per point. Frames are kept in memory only in this form.
struct Luma: Equatable, Sendable {
	let width: Int
	let height: Int
	var pixels: [UInt8]

	init(width: Int, height: Int, pixels: [UInt8]) {
		precondition(pixels.count == width * height)
		self.width = width
		self.height = height
		self.pixels = pixels
	}

	init(width: Int, height: Int, fill: UInt8) {
		self.init(width: width, height: height, pixels: Array(repeating: fill, count: width * height))
	}

	/// Converts a crop of a BGRA buffer with Rec. 709 weights.
	init(bgra base: UnsafeRawPointer, bytesPerRow: Int, x: Int, y: Int, width: Int, height: Int) {
		var pixels = [UInt8](repeating: 0, count: width * height)
		pixels.withUnsafeMutableBufferPointer { out in
			for row in 0..<height {
				let line = base.advanced(by: (y + row) * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
				for col in 0..<width {
					let b = UInt32(line[col * 4]), g = UInt32(line[col * 4 + 1]), r = UInt32(line[col * 4 + 2])
					out[row * width + col] = UInt8((54 * r + 183 * g + 19 * b) >> 8)
				}
			}
		}
		self.init(width: width, height: height, pixels: pixels)
	}

	static func hash(bgra base: UnsafeRawPointer, bytesPerRow: Int, x: Int, y: Int, width: Int, height: Int) -> UInt64 {
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325
		for row in 0..<height {
			let line = base.advanced(by: (y + row) * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
			for col in 0..<width {
				let pixel = line.advanced(by: col * 4)
				let luma = (54 * UInt32(pixel[2]) + 183 * UInt32(pixel[1]) + 19 * UInt32(pixel[0])) >> 8
				hash = (hash ^ UInt64(luma)) &* 0x100_0000_01b3
			}
		}
		return hash
	}

	subscript(x: Int, y: Int) -> UInt8 {
		get { pixels[y * width + x] }
		set { pixels[y * width + x] = newValue }
	}

	/// Mean absolute difference per pixel against a plane of the same size.
	func meanDifference(_ other: Luma) -> Double {
		precondition(width == other.width && height == other.height)
		guard !pixels.isEmpty else { return 0 }
		var sum = 0
		for i in pixels.indices { sum += abs(Int(pixels[i]) - Int(other.pixels[i])) }
		return Double(sum) / Double(pixels.count)
	}

	/// Mean absolute difference per pixel inside `rows` × `columns`.
	func meanDifference(_ other: Luma, rows: Range<Int>, columns: Range<Int>) -> Double {
		guard !rows.isEmpty, !columns.isEmpty else { return 0 }
		var sum = 0
		for y in rows {
			for x in columns { sum += abs(Int(self[x, y]) - Int(other[x, y])) }
		}
		return Double(sum) / Double(rows.count * columns.count)
	}

	/// Pixels inside `rows` × `columns` that differ from `other` by more than `threshold`.
	func changedPixels(_ other: Luma, rows: Range<Int>, columns: Range<Int>, threshold: Int) -> Int {
		var count = 0
		for y in rows {
			for x in columns where abs(Int(self[x, y]) - Int(other[x, y])) > threshold { count += 1 }
		}
		return count
	}

	/// FNV-1a over the pixels: equal crops hash alike, any change almost surely does not.
	func hash() -> UInt64 {
		var h: UInt64 = 0xcbf2_9ce4_8422_2325
		for byte in pixels {
			h ^= UInt64(byte)
			h = h &* 0x0000_0100_0000_01b3
		}
		return h
	}
}

/// Pure analysis of recorded frames.
enum FrameAnalysis {
	enum Axis: Sendable { case vertical, horizontal }

	/// Where `reference[rows, columns]` sits in `frame`, as a shift along `axis` (positive = down or right).
	/// Returns the lowest-cost shift with at least `minOverlap` lines in the frame, or nil when even that costs more
	/// than `maxCost` (mean absolute luma difference). `step` samples every n-th point across the axis.
	static func locate(rows: Range<Int>, columns: Range<Int>, of reference: Luma, in frame: Luma, axis: Axis,
		shifts: ClosedRange<Int>, minOverlap: Int, maxCost: Double, step: Int = 1) -> Int? {
		guard let best = bestShift(rows: rows, columns: columns, of: reference, in: frame, axis: axis, shifts: shifts,
			minOverlap: minOverlap, step: step), best.cost <= maxCost else { return nil }
		return best.shift
	}

	/// The lowest-cost shift and its cost, however high; nil only when no shift leaves `minOverlap` lines in the frame.
	static func bestShift(rows: Range<Int>, columns: Range<Int>, of reference: Luma, in frame: Luma, axis: Axis,
		shifts: ClosedRange<Int>, minOverlap: Int, step: Int = 1) -> (shift: Int, cost: Double)? {
		var best: (shift: Int, cost: Double)?
		let lines = axis == .vertical ? rows : columns
		let limit = axis == .vertical ? frame.height : frame.width
		let across = axis == .vertical ? columns : rows
		for shift in shifts {
			// Lines along the axis that land inside the frame after the shift.
			let low = max(lines.lowerBound, -shift), high = min(lines.upperBound, limit - shift)
			guard high - low >= minOverlap else { continue }
			let visible = low..<high
			let samples = visible.count * ((across.count + step - 1) / step)
			let budget = (best?.cost ?? .infinity) * Double(samples)
			var sum = 0
			for line in visible {
				for a in stride(from: across.lowerBound, to: across.upperBound, by: step) {
					let (rx, ry, fx, fy) = axis == .vertical ? (a, line, a, line + shift) : (line, a, line + shift, a)
					sum += abs(Int(reference[rx, ry]) - Int(frame[fx, fy]))
				}
				if Double(sum) > budget { break }
			}
			let cost = Double(sum) / Double(samples)
			if cost < (best?.cost ?? .infinity) { best = (shift, cost) }
		}
		return best
	}

	static func showsProgress(times: [Double], changed: [Bool], errors: [Double], after trigger: Double) -> Bool {
		times.indices.contains { i in times[i] >= trigger && changed[i] && errors[i] > 0.05 && errors[i] < 0.95 }
	}

	/// Seconds from `trigger` to the first frame after which every error stays within `tolerance`.
	/// Nil when the last frame is still unsettled, or when no frame was ever out of tolerance (nothing visibly moved).
	static func settleTime(times: [Double], errors: [Double], trigger: Double, tolerance: Double) -> Double? {
		guard let last = errors.lastIndex(where: { $0 > tolerance }), last + 1 < times.count else { return nil }
		return times[last + 1] - trigger
	}

	/// When a motion started on screen: one refresh before its first visibly changed frame at or after `trigger`
	/// (that frame already shows up to one refresh of motion), never earlier than the trigger.
	/// This leaves out the compositor's trigger-to-screen latency, which is not part of the motion.
	static func motionStart(times: [Double], changed: [Bool], trigger: Double, refresh: Double) -> Double {
		guard let first = times.indices.first(where: { times[$0] >= trigger && changed[$0] }) else { return trigger }
		return max(trigger, times[first] - refresh)
	}

	/// The x centroid of pixels in `rows` × `columns` that differ from `background` by more than `threshold`.
	static func centroid(_ frame: Luma, background: Luma, rows: Range<Int>, columns: Range<Int>, threshold: Int) -> Double? {
		var sum = 0, count = 0
		for y in rows {
			for x in columns where abs(Int(frame[x, y]) - Int(background[x, y])) > threshold {
				sum += x
				count += 1
			}
		}
		return count == 0 ? nil : Double(sum) / Double(count)
	}
}

/// Scroll smoothness from the presented frames' card-row hashes.
enum Smoothness {
	struct Frame: Equatable, Sendable {
		let time: Double
		let hash: UInt64
	}

	struct Result: Equatable {
		/// Frames presented inside the window.
		let presented: Int
		/// Presented frames whose card row differs from the frame before.
		let fresh: Int
		/// Intervals between presented frames (and the window's edges) within 1.5 refresh intervals.
		let onTime: Int
		let intervals: Int

		var freshFraction: Double { presented == 0 ? 0 : Double(fresh) / Double(presented) }
		var onTimeFraction: Double { intervals == 0 ? 0 : Double(onTime) / Double(intervals) }
		var passes: Bool { freshFraction >= Smoothness.required && onTimeFraction >= Smoothness.required }
	}

	enum InvalidTrial: String { case missingRow, panelChanged, driverIncomplete, incompleteWindow, incompleteTravel, noFrames }

	struct Trial {
		let result: Result?
		let reason: InvalidTrial?
		let distance: Double?
		let elapsed: Double?
		let captured: Int

		var evidence: [String: Any] {
			["invalidReason": reason?.rawValue as Any? ?? NSNull(), "distancePoints": distance as Any? ?? NSNull(),
				"elapsedSeconds": elapsed as Any? ?? NSNull(), "capturedFrames": captured]
		}
	}

	static func trial(frames: [Frame], first: Double?, last: Double?, finished: Bool, samePresentation: Bool,
		distance: Double, velocity: Double, seconds: Double, refresh: Double) -> Trial {
		let elapsed = first.flatMap { start in last.map { $0 - start } }
		func invalid(_ reason: InvalidTrial) -> Trial {
			Trial(result: nil, reason: reason, distance: distance, elapsed: elapsed, captured: frames.count)
		}
		guard samePresentation else { return invalid(.panelChanged) }
		guard finished else { return invalid(.driverIncomplete) }
		guard let first, let last, let window = window(first: first, last: last, duration: seconds, refresh: refresh) else {
			return invalid(.incompleteWindow)
		}
		guard travelIsComplete(distance, velocity: velocity, seconds: seconds, refresh: refresh) else { return invalid(.incompleteTravel) }
		let result = evaluate(frames, window: window, refresh: refresh)
		guard result.presented > 0 else { return invalid(.noFrames) }
		return Trial(result: result, reason: nil, distance: distance, elapsed: elapsed, captured: frames.count)
	}

	static let required = 0.95
	static let maxInterval = 1.5

	static func travelIsComplete(_ distance: Double, velocity: Double, seconds: Double, refresh: Double) -> Bool {
		abs(distance - abs(velocity) * seconds) <= max(1, abs(velocity) * refresh + 1)
	}

	static func window(first: Double, last: Double, duration: Double, refresh: Double) -> ClosedRange<Double>? {
		let start = first + 3 * refresh
		guard last - first >= duration, start < last else { return nil }
		return start...last
	}

	static func evaluate(_ frames: [Frame], window: ClosedRange<Double>, refresh: Double) -> Result {
		let sorted = frames.sorted { $0.time < $1.time }
		var previous = sorted.last { $0.time < window.lowerBound }?.hash
		var presented = 0, fresh = 0
		var times = [window.lowerBound]
		for frame in sorted where window.contains(frame.time) {
			presented += 1
			if let previous, previous != frame.hash { fresh += 1 }
			previous = frame.hash
			times.append(frame.time)
		}
		times.append(window.upperBound)
		let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
		let onTime = gaps.filter { $0 <= maxInterval * refresh + 1e-9 }.count
		return Result(presented: presented, fresh: fresh, onTime: onTime, intervals: gaps.count)
	}
}
