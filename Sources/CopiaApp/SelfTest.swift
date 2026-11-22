import AppKit
import CopiaUI

/// `Copia --selftest <json> [--hold <seconds>]`: opens and closes the strip through the same path as ⌘Y,
/// ten times on every display, and logs what the window system reports. Exits nonzero on any violation.
@MainActor
public enum SelfTest {
	struct Sample: Codable {
		var display: Int
		var cycle: Int
		var panelIdentity: String
		var panelVisible: Bool
		var panelIsKey: Bool
		var copiaIsFrontmost: Bool
		var panelScreen: String?
		var requestedScreen: String?
		var panelFrame: String
		var visibleFrame: String?
		var frameProblems: [String]
		var typedQuery: String
		var cardsMountedAfterClose: Bool
	}

	/// The panel must be exactly `PanelLayout.windowFrame(in:)` for its screen's visible frame, and lie inside that frame.
	/// Half a point of slack allows for backing-scale rounding.
	static func frameViolations(panel: CGRect, visible: CGRect) -> [String] {
		let slack: CGFloat = 0.5
		let expected = PanelLayout.windowFrame(in: visible)
		func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= slack }
		var problems: [String] = []
		if !(near(panel.minX, expected.minX) && near(panel.minY, expected.minY)
			&& near(panel.width, expected.width) && near(panel.height, expected.height)) {
			problems.append("panel frame \(panel) is not the layout frame \(expected)")
		}
		if !visible.insetBy(dx: -slack, dy: -slack).contains(panel) {
			problems.append("panel frame \(panel) leaves the visible frame \(visible)")
		}
		return problems
	}

	public static func run(controller: AppController, output: URL, hold: Double) async -> Int32 {
		var samples: [Sample] = []
		var violations: [String] = []
		let identity = ObjectIdentifier(controller.panel).debugDescription

		let screens = NSScreen.screens
		cycles: for (index, screen) in screens.enumerated() {
			for cycle in 0..<10 {
				let tag = "display \(index) cycle \(cycle)", closeCount = controller.model.closeCount
				guard !controller.panel.isVisible, !controller.model.cardsMounted, !controller.model.isClosing else {
					violations.append("\(tag): history was not closed at cycle start")
					break cycles
				}
				func samePresentation() -> Bool {
					controller.panel.isVisible && controller.panel.isKeyWindow && controller.model.cardsMounted
						&& !controller.model.isClosing && controller.model.closeCount == closeCount
				}
				controller.toggleHistory(on: screen)
				try? await Task.sleep(for: .milliseconds(cycle == 0 && index == 0 ? Int(hold * 1000) : 250))
				// The frame the strip should fill: the screen it opened on, or the benchmark's override.
				let visible = controller.visibleFrameOverride ?? controller.panel.screen?.visibleFrame
				let frameProblems = visible.map { Self.frameViolations(panel: controller.panel.frame, visible: $0) }
					?? ["panel is on no screen"]
				// Type one character through the window server's key path, as a user would.
				let typed = samePresentation() && Self.type("q", into: controller.panel)
				try? await Task.sleep(for: .milliseconds(60))
				let query = controller.model.query
				controller.model.query = ""
				var sample = Sample(display: index, cycle: cycle, panelIdentity: ObjectIdentifier(controller.panel).debugDescription,
					panelVisible: controller.panel.isVisible, panelIsKey: controller.panel.isKeyWindow,
					copiaIsFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
					panelScreen: controller.panel.screen?.localizedName, requestedScreen: screen.localizedName,
					panelFrame: NSStringFromRect(controller.panel.frame), visibleFrame: visible.map(NSStringFromRect),
					frameProblems: frameProblems,
					typedQuery: typed ? query : "<not sent>",
					cardsMountedAfterClose: false)
				if samePresentation() {
					controller.toggleHistory(on: screen)
				} else {
					violations.append("\(tag): history presentation interrupted")
				}
				try? await Task.sleep(for: .milliseconds(400))
				sample.cardsMountedAfterClose = controller.model.cardsMounted || controller.panel.isVisible
				samples.append(sample)

				if sample.panelIdentity != identity { violations.append("\(tag): panel recreated") }
				if !sample.panelVisible { violations.append("\(tag): panel not visible") }
				if !sample.panelIsKey { violations.append("\(tag): panel not key, typing would not reach search") }
				if sample.copiaIsFrontmost { violations.append("\(tag): Copia became the active app") }
				if sample.panelScreen != sample.requestedScreen { violations.append("\(tag): opened on \(sample.panelScreen ?? "nil"), requested \(sample.requestedScreen ?? "nil")") }
				for problem in sample.frameProblems { violations.append("\(tag): \(problem)") }
				if sample.typedQuery != "q" { violations.append("\(tag): typing reached \"\(sample.typedQuery)\", not the search") }
				if sample.cardsMountedAfterClose { violations.append("\(tag): still visible after close") }
				if !violations.isEmpty { break cycles }
			}
		}

		var settingsFirstAction = false
		if !screens.isEmpty, violations.isEmpty, samples.count == screens.count * 10 {
			let pid = ProcessInfo.processInfo.processIdentifier
			let initiallyInactive = NSWorkspace.shared.frontmostApplication?.processIdentifier != pid
			controller.model.actions.openSettings()
			let settings = controller.settings()
			for _ in 0..<100 where !settings.isKeyWindow || !settings.isMainWindow || NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { try? await Task.sleep(for: .milliseconds(10)) }
			settingsFirstAction = initiallyInactive && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && settings.isVisible && settings.isKeyWindow && settings.isMainWindow
			if !settingsFirstAction { violations.append("one Settings action did not activate the inactive app and its window") }
			controller.openSettings()
			if settings !== controller.settings() { violations.append("a repeated Settings action created another window") }
			settings.orderOut(nil)
		} else if violations.isEmpty {
			violations.append("no complete display cycles")
		}

		let report: [String: Any] = [
			"schema": 4,
			"settingsFirstAction": settingsFirstAction,
			// A full-screen Space cannot be entered from a script reliably; run the same check by hand over one.
			"fullScreenSpace": "manual",
			"displays": screens.count,
			"cycles": samples.count,
			"violations": violations,
			"samples": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(samples))) ?? [],
		]
		do {
			let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
			try data.write(to: output)
		} catch { return 1 }
		return violations.isEmpty ? 0 : 1
	}
}

extension SelfTest {
	/// Posts a key-down and key-up for `character` to the panel's window number. Returns false if no event could be made.
	static func type(_ character: String, into panel: NSPanel) -> Bool {
		guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: panel.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
			isARepeat: false, keyCode: 12),
			let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: panel.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
			isARepeat: false, keyCode: 12)
		else { return false }
		panel.sendEvent(down)
		panel.sendEvent(up)
		return true
	}
}
