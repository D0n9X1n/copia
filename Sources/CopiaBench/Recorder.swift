import AppKit
import CoreMedia
import ScreenCaptureKit

/// Host time in seconds: the clock ScreenCaptureKit stamps frames with, and the one display links use.
enum HostClock {
	static func seconds(_ ticks: UInt64) -> Double {
		var timebase = mach_timebase_info_data_t()
		mach_timebase_info(&timebase)
		return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
	}

	static var now: Double { seconds(mach_absolute_time()) }
}

/// An opaque, bench-owned gradient placed directly behind the panel at the next lower level for the whole recording,
/// so the glass only ever samples it. The gradient runs left to right only: a vertical slide stays a pure translation.
@MainActor
final class Wallpaper {
	let window: NSWindow

	init(behind panel: NSWindow) {
		let frame = panel.frame.insetBy(dx: -40, dy: -40)
		window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
		window.isOpaque = true
		window.backgroundColor = .black
		window.hasShadow = false
		window.ignoresMouseEvents = true
		window.isReleasedWhenClosed = false
		window.animationBehavior = .none
		window.collectionBehavior = panel.collectionBehavior
		window.level = NSWindow.Level(rawValue: panel.level.rawValue - 1)
		let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
		view.wantsLayer = true
		let gradient = CAGradientLayer()
		gradient.frame = view.bounds
		gradient.startPoint = CGPoint(x: 0, y: 0.5)
		gradient.endPoint = CGPoint(x: 1, y: 0.5)
		gradient.colors = [(0.95, 0.42, 0.24), (0.98, 0.80, 0.30), (0.30, 0.70, 0.45), (0.20, 0.45, 0.85),
			(0.55, 0.30, 0.75), (0.90, 0.35, 0.55), (0.25, 0.75, 0.80), (0.85, 0.85, 0.85)]
			.map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
		view.layer?.addSublayer(gradient)
		window.contentView = view
	}

	func show() { window.orderFrontRegardless() }
	func hide() { window.orderOut(nil) }
}

/// Records the bench's own panel and wallpaper windows with ScreenCaptureKit. Frames stay in memory as luma planes.
final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
	struct Frame: Sendable {
		let time: Double
		let luma: Luma
	}

	enum Mode: Sendable {
		case idle
		/// Keep every complete frame.
		case planes
		/// Keep only a hash of `rows` per frame.
		case hashes(rows: Range<Int>)
	}

	enum Failure: Error, CustomStringConvertible {
		case windowsNotShareable(found: Int)
		case noDisplay
		var description: String {
			switch self {
			case let .windowsNotShareable(found): "the bench's panel and wallpaper are not shareable (found \(found) of 2)"
			case .noDisplay: "no shareable display for the panel"
			}
		}
	}

	let width: Int
	let height: Int
	private let lock = NSLock()
	private var mode: Mode = .idle
	private var frames: [Frame] = []
	private var hashes: [Smoothness.Frame] = []
	private var latest: Frame?
	private var stream: SCStream?
	private let queue = DispatchQueue(label: "copia-bench.frames", qos: .userInteractive)

	init(width: Int, height: Int) {
		self.width = width
		self.height = height
	}

	/// Starts recording the panel's frame. The filter holds only the bench's own panel and wallpaper windows.
	@MainActor
	func start(panel: NSWindow, wallpaper: NSWindow, framesPerSecond: Int) async throws {
		let content = try await SCShareableContent.currentProcess
		let ids = Set([panel.windowNumber, wallpaper.windowNumber].map { CGWindowID($0) })
		let windows = content.windows.filter { ids.contains($0.windowID) }
		guard windows.count == 2 else { throw Failure.windowsNotShareable(found: windows.count) }
		guard let screen = panel.screen ?? NSScreen.main,
			let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
			let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.noDisplay }
		let filter = SCContentFilter(display: display, including: windows)
		let config = SCStreamConfiguration()
		let frame = panel.frame
		config.sourceRect = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
			width: CGFloat(width), height: CGFloat(height))
		config.width = width
		config.height = height
		config.captureResolution = .nominal
		config.pixelFormat = kCVPixelFormatType_32BGRA
		config.showsCursor = false
		config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
		config.queueDepth = 8
		let stream = SCStream(filter: filter, configuration: config, delegate: nil)
		try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
		try await stream.startCapture()
		self.stream = stream
	}

	@MainActor
	func stop() async {
		try? await stream?.stopCapture()
		stream = nil
	}

	/// Starts keeping frames. Planes start with the latest frame, so a trial knows the state before its trigger.
	func begin(_ newMode: Mode) {
		lock.withLock {
			mode = newMode
			frames = []
			hashes = []
			if case .planes = newMode, let latest { frames = [latest] }
		}
	}

	func endPlanes() -> [Frame] {
		lock.withLock {
			mode = .idle
			defer { frames = [] }
			return frames
		}
	}

	func endHashes() -> [Smoothness.Frame] {
		lock.withLock {
			mode = .idle
			defer { hashes = [] }
			return hashes
		}
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
		guard type == .screen, sample.isValid,
			let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
			let info = attachments.first,
			let rawStatus = info[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
			let ticks = info[.displayTime] as? UInt64,
			let buffer = sample.imageBuffer else { return }
		CVPixelBufferLockBaseAddress(buffer, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
		guard let base = CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetWidth(buffer) >= width,
			CVPixelBufferGetHeight(buffer) >= height else { return }
		let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
		let time = HostClock.seconds(ticks)
		let mode = lock.withLock { self.mode }
		if case let .hashes(rows) = mode {
			let band = Luma(bgra: base, bytesPerRow: bytesPerRow, x: 0, y: rows.lowerBound, width: width, height: rows.count)
			let frame = Smoothness.Frame(time: time, hash: band.hash())
			lock.withLock { hashes.append(frame) }
			return
		}
		let frame = Frame(time: time, luma: Luma(bgra: base, bytesPerRow: bytesPerRow, x: 0, y: 0, width: width, height: height))
		lock.withLock {
			latest = frame
			if case .planes = self.mode { frames.append(frame) }
		}
	}
}
