import Testing
import AppKit
import SwiftUI
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

/// The real StripPanel and StripView, driven by real NSEvents sent through the window, far off every screen.
@MainActor
final class InputHost {
	let model = StripModel(clips: Fixtures.mixed)
	let panel = StripPanel()
	let focus = SearchFocus()
	let log = ActionLog()

	init() {
		AccessibilityNode.enableInProcess()
		model.actions = log.actions()
		panel.host.rootView = AnyView(StripView(model: model, focus: focus, thumbnails: ThumbnailCache(), now: { Fixtures.now }))
		// As AppController wires it: ⌘ held shows the 1–9 badges.
		panel.onFlagsChanged = { [unowned self] flags in model.commandHeld = flags.contains(.command) }
		panel.alphaValue = 0
		panel.setFrame(CGRect(x: -6000, y: -6000, width: 1440, height: Theme.panelHeight), display: false)
		model.open()
		panel.orderFrontRegardless()
		panel.makeKey()
		model.animateIn()
	}

	func close() { panel.orderOut(nil) }

	func settle(_ milliseconds: Int = 150) async {
		try? await Task.sleep(for: .milliseconds(milliseconds))
		panel.host.layoutSubtreeIfNeeded()
	}

	func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
		for type in [NSEvent.EventType.keyDown, .keyUp] {
			let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
				isARepeat: false, keyCode: code)!
			panel.sendEvent(event)
		}
	}

	func flags(_ flags: NSEvent.ModifierFlags) {
		let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
			timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
			characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
		panel.sendEvent(event)
	}

	/// Clicks `count` times at the center of the element (screen coordinates).
	func click(_ node: AXNode, count: Int) {
		let point = panel.convertPoint(fromScreen: CGPoint(x: node.frame.midX, y: node.frame.midY))
		for n in 1...count {
			for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
				let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
					windowNumber: panel.windowNumber, context: nil, eventNumber: n, clickCount: n, pressure: type == .leftMouseDown ? 1 : 0)!
				panel.sendEvent(event)
			}
		}
	}

	var cards: [AXNode] {
		var seen = Set<ObjectIdentifier>()
		return AXNode(panel.host).all.filter { !$0.actions.isEmpty && seen.insert(ObjectIdentifier($0.object)).inserted }
	}
}

@MainActor
@Suite(.serialized) struct InputTests {
	static let leftArrow = (String(UnicodeScalar(NSLeftArrowFunctionKey)!), UInt16(123))
	static let rightArrow = (String(UnicodeScalar(NSRightArrowFunctionKey)!), UInt16(124))

	@Test func aPrintableCharacterStartsTheQuery() async {
		let host = InputHost()
		defer { host.close() }
		await host.settle()
		host.focus.focus()
		#expect(host.panel.isKeyWindow)
		host.key("r", code: 15)
		host.key("e", code: 14)
		await host.settle()
		#expect(host.model.query == "re")
		#expect(host.model.visibleClips.allSatisfy { $0.text.localizedStandardContains("re") || !$0.fileNames.isEmpty })
	}

	@Test func arrowsMoveTheSelectionAndStopAtTheEnds() async {
		let host = InputHost()
		defer { host.close() }
		await host.settle()
		host.focus.focus()
		host.key(Self.leftArrow.0, code: Self.leftArrow.1)
		#expect(host.model.selectedID == Fixtures.mixed[0].id)
		host.key(Self.rightArrow.0, code: Self.rightArrow.1)
		#expect(host.model.selectedID == Fixtures.mixed[1].id)
		for _ in 0..<12 { host.key(Self.rightArrow.0, code: Self.rightArrow.1) }
		#expect(host.model.selectedID == Fixtures.mixed[8].id)
		#expect(host.model.query.isEmpty)
	}

	@Test func holdingCommandShowsBadges() async {
		let host = InputHost()
		defer { host.close() }
		await host.settle()
		host.flags(.command)
		await host.settle()
		#expect(host.model.commandHeld)
		#expect(host.model.badge(for: Fixtures.mixed[0].id) == 1)
		host.flags([])
		#expect(!host.model.commandHeld)
	}

	@Test func doubleClickingACardPastesIt() async throws {
		let host = InputHost()
		defer { host.close() }
		await host.settle()
		let clip = Fixtures.mixed[2]
		let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: clip, now: Fixtures.now).label })
		host.click(card, count: 2)
		await host.settle(300)
		#expect(host.log.entries == ["paste \(clip.id) plain=false"])
		#expect(host.model.isClosing || !host.model.cardsMounted)
	}
}
