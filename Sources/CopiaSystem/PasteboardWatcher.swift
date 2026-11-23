import AppKit
import CopiaCore

/// The parts of the general pasteboard the watcher reads. Tests supply a fake.
@MainActor
public protocol PasteboardSource: AnyObject {
	var changeCount: Int { get }
	var typeIdentifiers: Set<String> { get }
	/// Each item's stored representations, in pasteboard order.
	func readItems() -> [PasteboardItemData]
}

@MainActor
public final class GeneralPasteboard: PasteboardSource {
	let pasteboard: NSPasteboard
	public init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

	public var changeCount: Int { pasteboard.changeCount }
	public var typeIdentifiers: Set<String> { Set((pasteboard.types ?? []).map(\.rawValue)) }

	public func readItems() -> [PasteboardItemData] {
		(pasteboard.pasteboardItems ?? []).compactMap { item in
			let reps: [(type: String, data: Data)] = item.types.compactMap { type in
				guard PasteboardTypes.stored.contains(type.rawValue), let data = item.data(forType: type) else { return nil }
				return (type: type.rawValue, data: data)
			}
			return reps.isEmpty ? nil : PasteboardItemData(reps)
		}
	}
}

/// Polls the pasteboard every 0.5 s and emits drafts for changes worth keeping.
/// macOS has no public change notification; two copies within one interval keep only the second.
@MainActor
public final class PasteboardWatcher {
	public var onDraft: (ClipDraft) -> Void = { _ in }
	/// Every pasteboard change the watcher sees, kept or skipped, paused or not, before any read. Copia's own writes included.
	public var onChange: (Int) -> Void = { _ in }
	public var ignoredApps: Set<String>
	public private(set) var paused = false
	public private(set) var pollCount = 0
	public private(set) var lastDecision: Capture.Decision?

	let source: PasteboardSource
	/// Stamps copies.
	let now: () -> Date
	/// Stamps activations and polls: monotonic, so a wall clock that steps back cannot reorder the windows.
	let uptime: () -> TimeInterval
	let frontmost: () -> String?
	let appName: (String) -> String?
	private var lastChange: Int
	/// The pasteboard change of the copy handed to `onDraft`, set just before the call.
	public private(set) var lastCaptureChange = 0
	private var log: ActivationLog
	private var timer: Timer?
	private lazy var timerTarget = PollTarget(self)
	private var observer: NSObjectProtocol?

	public init(source: PasteboardSource, ignoredApps: Set<String> = [],
		now: @escaping () -> Date = Date.init,
		uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
		frontmost: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
		appName: @escaping (String) -> String? = { id in
			NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
				?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) }
		}) {
		self.source = source
		self.ignoredApps = ignoredApps
		self.now = now
		self.uptime = uptime
		self.frontmost = frontmost
		self.appName = appName
		lastChange = source.changeCount
		log = ActivationLog(frontmost: frontmost(), at: uptime())
	}

	public func start(observingWorkspace: Bool = true) {
		if observingWorkspace {
			observer = NSWorkspace.shared.notificationCenter.addObserver(
				forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
					let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
					MainActor.assumeIsolated { if let id { self?.appActivated(id) } }
				}
		}
		let timer = makeTimer()
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	/// Builds the polling timer without scheduling it, so its configuration can be tested in isolation.
	func makeTimer() -> Timer {
		let timer = Timer(timeInterval: 0.5, target: timerTarget, selector: #selector(PollTarget.fire(_:)),
			userInfo: nil, repeats: true)
		timer.tolerance = 0.1
		return timer
	}

	/// The timer runs on the main run loop. Its target must not keep the watcher alive.
	@MainActor private final class PollTarget: NSObject {
		weak var watcher: PasteboardWatcher?
		init(_ watcher: PasteboardWatcher) { self.watcher = watcher }
		@objc func fire(_ timer: Timer) {
			guard let watcher else { timer.invalidate(); return }
			watcher.tick()
		}
	}

	public func stop() {
		timer?.invalidate()
		timer = nil
		if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
		observer = nil
	}

	/// Logs an activation at the time it is reported.
	public func appActivated(_ bundleID: String) { log.activated(bundleID, at: uptime()) }

	public func setPaused(_ value: Bool) {
		paused = value
		// Resuming starts from the current contents, so anything copied while paused is never captured.
		if !value { lastChange = source.changeCount; _ = log.candidates(until: uptime(), currentFrontmost: frontmost()) }
	}

	/// One poll. Called by the timer; tests call it directly.
	public func tick() {
		pollCount += 1
		let change = source.changeCount
		let pollTime = uptime()
		// Every poll closes the window, so only apps in front since the previous poll can count as the source.
		guard change != lastChange else { log.roll(at: pollTime); return }
		lastChange = change
		onChange(change)
		let candidates = log.candidates(until: pollTime, currentFrontmost: frontmost())
		guard !paused else { return }
		let types = source.typeIdentifiers
		// Check the type list before reading any data, so concealed content is never read.
		var decision = Capture.decide(types: types, draft: nil, candidates: candidates, ignoredApps: ignoredApps)
		guard decision == .skipEmpty else { lastDecision = decision; return }
		let own = Bundle.main.bundleIdentifier
		let sourceID = ActivationLog.source(of: candidates, excluding: own)
		let items = source.readItems()
		// A copy that landed during the read was checked against the old types; drop it and let the next poll judge it.
		guard source.changeCount == change else { return }
		let draft = ClipDraft(items: items, sourceBundleID: sourceID,
			sourceName: sourceID.flatMap(appName), copiedAt: now())
		decision = Capture.decide(types: types, draft: draft, candidates: candidates, ignoredApps: ignoredApps)
		lastDecision = decision
		if decision == .keep { lastCaptureChange = change; onDraft(draft) }
	}
}
