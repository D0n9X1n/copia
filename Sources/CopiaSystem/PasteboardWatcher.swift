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
	public init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

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
	public var ignoredApps: Set<String>
	public private(set) var paused = false
	public private(set) var lastDecision: Capture.Decision?

	let source: PasteboardSource
	let now: () -> Date
	let frontmost: () -> String?
	let appName: (String) -> String?
	private var lastChange: Int
	private var log: ActivationLog
	private var timer: Timer?
	private var observer: NSObjectProtocol?

	public init(source: PasteboardSource = GeneralPasteboard(), ignoredApps: Set<String> = [],
		now: @escaping () -> Date = Date.init,
		frontmost: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
		appName: @escaping (String) -> String? = { id in
			NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
				?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) }
		}) {
		self.source = source
		self.ignoredApps = ignoredApps
		self.now = now
		self.frontmost = frontmost
		self.appName = appName
		lastChange = source.changeCount
		log = ActivationLog(frontmost: frontmost())
	}

	public func start() {
		observer = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
			let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
			MainActor.assumeIsolated { if let id { self?.appActivated(id) } }
		}
		let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.tick() }
		}
		timer.tolerance = 0.1
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	public func stop() {
		timer?.invalidate()
		timer = nil
		if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
		observer = nil
	}

	public func appActivated(_ bundleID: String) { log.activated(bundleID) }

	public func setPaused(_ value: Bool) {
		paused = value
		// Resuming starts from the current contents, so anything copied while paused is never captured.
		if !value { lastChange = source.changeCount; _ = log.candidatesAndReset(currentFrontmost: frontmost()) }
	}

	/// One poll. Called by the timer; tests call it directly.
	public func tick() {
		let change = source.changeCount
		guard change != lastChange else { return }
		lastChange = change
		let current = frontmost()
		let candidates = log.candidatesAndReset(currentFrontmost: current)
		guard !paused else { return }
		let types = source.typeIdentifiers
		// Check the type list before reading any data, so concealed content is never read.
		var decision = Capture.decide(types: types, draft: nil, candidates: candidates, ignoredApps: ignoredApps)
		guard decision == .skipEmpty else { lastDecision = decision; return }
		let own = Bundle.main.bundleIdentifier
		let sourceID = ActivationLog.source(of: candidates, excluding: own)
		let draft = ClipDraft(items: source.readItems(), sourceBundleID: sourceID,
			sourceName: sourceID.flatMap(appName), copiedAt: now())
		decision = Capture.decide(types: types, draft: draft, candidates: candidates, ignoredApps: ignoredApps)
		lastDecision = decision
		if decision == .keep { onDraft(draft) }
	}
}
