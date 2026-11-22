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
		var frontmostBundleID: String?
		var panelScreen: String?
		var mouseScreen: String?
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
		let savedMouse = CGEvent(source: nil)?.location
		var samples: [Sample] = []
		var violations: [String] = []
		let identity = ObjectIdentifier(controller.panel).debugDescription
		let ownPID = ProcessInfo.processInfo.processIdentifier

		for (index, screen) in NSScreen.screens.enumerated() {
			// Move the pointer to this display; the strip opens on the screen under the mouse.
			let mainHeight = NSScreen.screens[0].frame.maxY
			let target = CGPoint(x: screen.frame.midX, y: mainHeight - screen.frame.midY)
			CGWarpMouseCursorPosition(target)
			try? await Task.sleep(for: .milliseconds(150))

			for cycle in 0..<10 {
				controller.toggleHistory()
				try? await Task.sleep(for: .milliseconds(cycle == 0 && index == 0 ? Int(hold * 1000) : 250))
				let mouse = NSEvent.mouseLocation
				let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
				// The frame the strip should fill: the screen it opened on, or the benchmark's override.
				let visible = controller.visibleFrameOverride ?? controller.panel.screen?.visibleFrame
				let frameProblems = visible.map { Self.frameViolations(panel: controller.panel.frame, visible: $0) }
					?? ["panel is on no screen"]
				// Type one character through the window server's key path, as a user would.
				let typed = Self.type("q", into: controller.panel)
				try? await Task.sleep(for: .milliseconds(60))
				let query = controller.model.query
				controller.model.query = ""
				let front = NSWorkspace.shared.frontmostApplication
				var sample = Sample(display: index, cycle: cycle, panelIdentity: ObjectIdentifier(controller.panel).debugDescription,
					panelVisible: controller.panel.isVisible, panelIsKey: controller.panel.isKeyWindow,
					copiaIsFrontmost: front?.processIdentifier == ownPID, frontmostBundleID: front?.bundleIdentifier,
					panelScreen: controller.panel.screen?.localizedName, mouseScreen: mouseScreen?.localizedName,
					panelFrame: NSStringFromRect(controller.panel.frame), visibleFrame: visible.map(NSStringFromRect),
					frameProblems: frameProblems,
					typedQuery: typed ? query : "<not sent>",
					cardsMountedAfterClose: false)
				controller.toggleHistory()
				try? await Task.sleep(for: .milliseconds(400))
				sample.cardsMountedAfterClose = controller.model.cardsMounted || controller.panel.isVisible
				samples.append(sample)

				let tag = "display \(index) cycle \(cycle)"
				if sample.panelIdentity != identity { violations.append("\(tag): panel recreated") }
				if !sample.panelVisible { violations.append("\(tag): panel not visible") }
				if !sample.panelIsKey { violations.append("\(tag): panel not key, typing would not reach search") }
				if sample.copiaIsFrontmost { violations.append("\(tag): Copia became the active app") }
				if sample.panelScreen != sample.mouseScreen { violations.append("\(tag): opened on \(sample.panelScreen ?? "nil"), mouse on \(sample.mouseScreen ?? "nil")") }
				for problem in sample.frameProblems { violations.append("\(tag): \(problem)") }
				if sample.typedQuery != "q" { violations.append("\(tag): typing reached \"\(sample.typedQuery)\", not the search") }
				if sample.cardsMountedAfterClose { violations.append("\(tag): still visible after close") }
			}
		}
		if let savedMouse { CGWarpMouseCursorPosition(savedMouse) }

		let report: [String: Any] = [
			"schema": 3,
			// A full-screen Space cannot be entered from a script reliably; run the same check by hand over one.
			"fullScreenSpace": "manual",
			"displays": NSScreen.screens.count,
			"cycles": samples.count,
			"violations": violations,
			"samples": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(samples))) ?? [],
		]
		if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
			try? data.write(to: output)
		}
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
		NSApp.postEvent(down, atStart: false)
		NSApp.postEvent(up, atStart: false)
		return true
	}
}

/// Opt-in diagnostics: set COPIA_DEBUG=1 to append panel events to /tmp/copia-debug.log.
enum CopiaDebug {
	static func log(_ line: String) {
		guard ProcessInfo.processInfo.environment["COPIA_DEBUG"] != nil else { return }
		let url = URL(fileURLWithPath: "/tmp/copia-debug.log")
		let text = "\(Date().timeIntervalSince1970) \(line)\n"
		if let handle = try? FileHandle(forWritingTo: url) {
			handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
		} else {
			try? Data(text.utf8).write(to: url)
		}
	}
}
