import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CopiaCore
import CopiaUI

/// Puts stored items back on the pasteboard and, with Accessibility, sends ⌘V to the previous app.
@MainActor
public final class Paster {
	let pasteboard: NSPasteboard
	let isTrusted: () -> Bool
	let postPaste: () -> Void
	let waitForFront: (NSRunningApplication) async -> Bool

	public init(pasteboard: NSPasteboard = .general,
		isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
		postPaste: @escaping () -> Void = Paster.postCommandV,
		waitForFront: @escaping (NSRunningApplication) async -> Bool = Paster.activateAndWait) {
		self.pasteboard = pasteboard
		self.isTrusted = isTrusted
		self.postPaste = postPaste
		self.waitForFront = waitForFront
	}

	/// Writes the items, tagged so capture skips them. Plain keeps only the text.
	public func write(_ items: [PasteboardItemData], plain: Bool) {
		let source = Bundle.main.bundleIdentifier ?? "app.copia.Copia"
		let objects: [NSPasteboardItem] = items.compactMap { item in
			let reps = plain ? Self.plainRepresentations(item) : item.representations
			guard !reps.isEmpty else { return nil }
			let out = NSPasteboardItem()
			for rep in reps { out.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type)) }
			out.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardTypes.marker))
			out.setString(source, forType: NSPasteboard.PasteboardType(PasteboardTypes.source))
			return out
		}
		pasteboard.clearContents()
		pasteboard.writeObjects(objects)
	}

	/// Plain text only: the item's string, else the text of its rich text, else its file's path.
	static func plainRepresentations(_ item: PasteboardItemData) -> [(type: String, data: Data)] {
		var text = Capture.plainText(ClipDraft(items: [item], copiedAt: .now))
		if text.isEmpty, let url = Capture.fileURLs(ClipDraft(items: [item], copiedAt: .now)).first { text = url.path }
		return text.isEmpty ? [] : [(type: PasteboardTypes.string, data: Data(text.utf8))]
	}

	/// Copies, then pastes into `target` once it is frontmost. Calls `beginClose` before sending ⌘V.
	public func paste(_ items: [PasteboardItemData], plain: Bool, target: NSRunningApplication?,
		beginClose: @escaping @MainActor () -> Void) async -> PasteResult {
		write(items, plain: plain)
		guard isTrusted() else { return .accessibilityRequired }
		beginClose()
		guard let target, await waitForFront(target) else { return .copied }
		guard isTrusted() else { return .accessibilityRequired }
		postPaste()
		return .pasted
	}

	/// How long the target must stay frontmost before ⌘V is sent.
	public static let settleMilliseconds = 30
	/// The longest the whole wait may take, settle included.
	public static let waitBudgetMilliseconds = 300

	/// Reactivates the target if needed and waits for it to be frontmost, 300 ms at most including the settle.
	public static func activateAndWait(_ app: NSRunningApplication) async -> Bool {
		await activateAndWait(pid: app.processIdentifier,
			frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
			activate: { app.activate() },
			sleep: { try? await Task.sleep(for: .milliseconds($0)) })
	}

	/// The target must still be frontmost after the settle delay; a switch during it would send ⌘V to another app.
	static func activateAndWait(pid: pid_t, frontmost: () -> pid_t?, activate: () -> Void,
		sleep: (Int) async -> Void, now: () -> ContinuousClock.Instant = { ContinuousClock.now }) async -> Bool {
		// The budget is elapsed time on a monotonic clock: a sleep that wakes late still counts in full.
		let start = now()
		let budget = Duration.milliseconds(waitBudgetMilliseconds), settle = Duration.milliseconds(settleMilliseconds)
		if frontmost() != pid { activate() }
		// Poll only while a full settle still fits in the budget; a target seen later is not pasted into.
		while now() - start + settle <= budget {
			if frontmost() == pid {
				await sleep(settleMilliseconds)
				return now() - start <= budget && frontmost() == pid
			}
			await sleep(10)
		}
		return false
	}

	/// Posts ⌘V. shortcut: uses the ANSI V key code, so non-QWERTY layouts without a QWERTY-⌘ variant may differ; map via UCKeyTranslate if users report it.
	public nonisolated static func postCommandV() {
		let source = CGEventSource(stateID: .combinedSessionState)
		source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
			state: .eventSuppressionStateSuppressionInterval)
		let key = CGKeyCode(kVK_ANSI_V)
		let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
		let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
		down?.flags = .maskCommand
		up?.flags = .maskCommand
		down?.post(tap: .cgSessionEventTap)
		up?.post(tap: .cgSessionEventTap)
	}
}

/// Permission state shown in onboarding and used before pasting.
public enum Permissions {
	public static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

	/// Shows the system prompt that adds Copia to the Accessibility list.
	public static func requestAccessibility() {
		let key = "AXTrustedCheckOptionPrompt" as CFString
		_ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
	}

	public static var pasteboardAccess: NSPasteboard.AccessBehavior { NSPasteboard.general.accessBehavior }

	public static func openAccessibilitySettings() {
		NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
	}

	public static func openPasteboardSettings() {
		NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
	}
}
