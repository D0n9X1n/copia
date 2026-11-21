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
		var stripInsideVisibleFrame: Bool
		var cardsMountedAfterClose: Bool
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
				let strip = PanelLayout.stripFrame(in: controller.panel.screen?.visibleFrame ?? .zero)
				let front = NSWorkspace.shared.frontmostApplication
				var sample = Sample(display: index, cycle: cycle, panelIdentity: ObjectIdentifier(controller.panel).debugDescription,
					panelVisible: controller.panel.isVisible, panelIsKey: controller.panel.isKeyWindow,
					copiaIsFrontmost: front?.processIdentifier == ownPID, frontmostBundleID: front?.bundleIdentifier,
					panelScreen: controller.panel.screen?.localizedName, mouseScreen: mouseScreen?.localizedName,
					stripInsideVisibleFrame: controller.panel.screen.map { $0.visibleFrame.contains(strip) } ?? false,
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
				if !sample.stripInsideVisibleFrame { violations.append("\(tag): strip outside the visible frame") }
				if sample.cardsMountedAfterClose { violations.append("\(tag): still visible after close") }
			}
		}
		if let savedMouse { CGWarpMouseCursorPosition(savedMouse) }

		let report: [String: Any] = [
			"schema": 1,
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
