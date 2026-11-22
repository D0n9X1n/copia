import Testing
import Observation
import AppKit
import SwiftUI
import CopiaCore
import CopiaFixtures
@testable import CopiaUI

/// The real StripPanel and StripView, driven by real NSEvents sent through the window, far off every screen.
@MainActor
final class InputHost {
	let model: StripModel
	let panel = StripPanel()
	let focus: SearchFocus
	let log = ActionLog()

	init(clips: [Clip] = Fixtures.mixed, focus: SearchFocus = SearchFocus(), reduced: Bool = false) {
		self.focus = focus
		model = StripModel(clips: clips)
		AccessibilityNode.enableInProcess()
		model.actions = log.actions()
		panel.host.rootView = AnyView(StripView(model: model, focus: focus, thumbnails: ThumbnailCache(), now: { Fixtures.now }, sources: .fixtures)
			.environment(\.copiaOverrides, CopiaOverrides(reduceTransparency: true, reduceMotion: reduced)))
		// As AppController wires it: ⌘ held shows the 1–9 badges.
		panel.onKeyEquivalent = { [unowned self] event in focus.handleKeyEquivalent(event, model: model) }
		panel.onFlagsChanged = { [unowned self] flags in model.commandHeld = flags.contains(.command) }
		panel.alphaValue = 0
		panel.setFrame(CGRect(x: -6000, y: -6000, width: 1440, height: Theme.panelHeight), display: false)
		model.open()
		panel.orderFrontRegardless()
		panel.makeKey()
		model.animateIn()
	}

	func close() { panel.makeFirstResponder(nil); panel.hide() }

	func settle(_ milliseconds: Int = 150) async {
		try? await Task.sleep(for: .milliseconds(milliseconds))
		panel.host.layoutSubtreeIfNeeded()
	}

	func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) {
		for type in [NSEvent.EventType.keyDown, .keyUp] {
			let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
				isARepeat: repeated, keyCode: code)!
			if flags.contains(.command) {
				if type == .keyDown { _ = panel.performKeyEquivalent(with: event) }
			} else {
				panel.sendEvent(event)
			}
		}
	}

	func flags(_ flags: NSEvent.ModifierFlags) {
		let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
			timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
			characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
		panel.sendEvent(event)
	}

	func mouse(_ type: NSEvent.EventType, at node: AXNode, count: Int = 1) {
		mouse(type, at: panel.convertPoint(fromScreen: CGPoint(x: node.frame.midX, y: node.frame.midY)), count: count)
	}

	func mouse(_ type: NSEvent.EventType, at point: CGPoint, count: Int = 1) {
		let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: panel.windowNumber, context: nil, eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
		panel.sendEvent(event)
	}

	/// Release a native mouse tracker from *its own* nested run loop. Pre-posting stops SwiftPM's outer async-main loop.
	func trackingClick(at point: CGPoint) {
		let number = panel.windowNumber
		RunLoop.main.perform(inModes: [.eventTracking]) {
			MainActor.assumeIsolated {
				let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
					modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number,
					context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
				NSApp.postEvent(up, atStart: true)
			}
		}
		mouse(.leftMouseDown, at: point)
	}

	func click(_ node: AXNode, count: Int) {
		let point = panel.convertPoint(fromScreen: CGPoint(x: node.frame.midX, y: node.frame.midY))
		for n in 1...count {
			mouse(.leftMouseDown, at: point, count: n)
			mouse(.leftMouseUp, at: point, count: n)
		}
	}

	var cards: [AXNode] {
		var seen = Set<ObjectIdentifier>()
		return AXNode(panel.host).all.filter { !$0.actions.isEmpty && seen.insert(ObjectIdentifier($0.object)).inserted }
	}
}

extension WindowTests {
	@MainActor @Suite struct InputTests {}
}

extension WindowTests.InputTests {
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

	@Test func markedTextKeepsCommandsInTheFieldEditorUntilCommitOrCancel() async throws {
		let commands: [(String, UInt16)] = [Self.leftArrow, Self.rightArrow, ("\r", 36), ("\u{7f}", 51), ("\u{1b}", 53)]
		for (characters, code) in commands {
			let host = InputHost()
			defer { host.close() }
			await host.settle()
			host.focus.focus()
			let editor = try #require(host.panel.firstResponder as? NSTextView)
			let field = try #require(host.focus.field)
			#expect(editor.isFieldEditor && field.currentEditor() === editor)
			host.model.select(Fixtures.mixed[1].id)
			editor.setMarkedText("re", selectedRange: NSRange(location: 1, length: 0),
				replacementRange: NSRange(location: NSNotFound, length: 0))
			#expect(editor.hasMarkedText())
			let selection = host.model.selectedID
			host.key(characters, code: code)
			// Inspect the actual key event before unrelated asynchronous input-service callbacks.
			let markedAfterKey = editor.hasMarkedText(), stringAfterKey = editor.string
			await host.settle()
			#expect(host.model.selectedID == selection, "key \(code)")
			#expect(host.log.entries.isEmpty, "key \(code)")
			#expect(!host.model.isClosing && host.model.cardsMounted, "key \(code)")
			// Native NSTextField may publish a query when Return or Backspace ends composition.
			if code == 53 {
				// Escape may cancel the marked range, or leave it with the input method; it never closes history.
				#expect(markedAfterKey ? stringAfterKey == "re" : stringAfterKey.isEmpty)
				#expect(host.model.query.isEmpty)
			} else if code == 123 || code == 124 {
				#expect(markedAfterKey && stringAfterKey == "re", "key \(code)")
				#expect(host.model.query.isEmpty)
			} else {
				#expect(!editor.hasMarkedText())
				#expect(host.model.query == (code == 36 ? "re" : "e"), "key \(code)")
			}
		}
	}

	@Test func committingOrCancellingMarkedTextRestoresNormalStripKeys() async throws {
		for commit in [true, false] {
			let host = InputHost()
			defer { host.close() }
			await host.settle()
			host.focus.focus()
			let editor = try #require(host.panel.firstResponder as? NSTextView)
			let field = try #require(host.focus.field)
			#expect(editor.isFieldEditor && field.currentEditor() === editor)
			let selection = host.model.selectedID
			editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
				replacementRange: NSRange(location: NSNotFound, length: 0))
			editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: editor.markedRange())
			await host.settle()
			#expect(editor.hasMarkedText())
			#expect(editor.string == "にほん")
			// setMarkedText alone does not send controlTextDidChange on this native field.
			#expect(host.model.query.isEmpty)
			#expect(host.model.selectedID == selection)
			#expect(host.log.entries.isEmpty)
			#expect(!host.model.isClosing && host.model.cardsMounted)

			// NSTextInputClient ends composition by replacing the marked range with a candidate;
			// cancelling replaces it with nothing. No coordinator calls or synthetic selectors.
			editor.insertText(commit ? "日本" : "", replacementRange: editor.markedRange())
			await host.settle()
			#expect(!editor.hasMarkedText())
			#expect(editor.string == (commit ? "日本" : ""))
			#expect(host.model.query == editor.string)
			#expect(host.log.entries.isEmpty)
			#expect(!host.model.isClosing && host.model.cardsMounted)

			// Escape clears the committed search rather than closing; cancel already left it empty.
			if commit {
				host.key("\u{1b}", code: 53)
				await host.settle()
			}
			#expect(host.model.query.isEmpty)
			host.key("r", code: 15)
			await host.settle()
			#expect(host.model.query == "r")
			host.key("\u{7f}", code: 51)
			await host.settle()
			#expect(host.model.query.isEmpty)
			#expect(host.log.entries.isEmpty)
			host.key("\t", code: 48)
			host.key(Self.rightArrow.0, code: Self.rightArrow.1)
			#expect(host.model.selectedID == Fixtures.mixed[1].id)
			host.key("\u{7f}", code: 51)
			await host.settle()
			#expect(host.log.entries == ["delete \(Fixtures.mixed[1].id)"])
			#expect(!host.model.clips.contains { $0.id == Fixtures.mixed[1].id })
			host.key("\r", code: 36)
			await host.settle()
			#expect(host.log.entries == ["delete \(Fixtures.mixed[1].id)", "write \(Fixtures.mixed[2].id) plain=false"])
			#expect(host.model.isClosing || !host.model.cardsMounted)
		}
	}

	@Test func holdingCommandShowsBadges() async {
		let host = InputHost()
		defer { host.close() }
		await host.settle()
		host.flags(.command)
		await host.settle()
		#expect(host.model.commandHeld)
		#expect(host.model.badge(at: 0) == 1)
		host.flags([])
		#expect(!host.model.commandHeld)
	}

	@Test func pointerDownMovesTheLensBeforeUpWithoutActivating() async throws {
		let host = InputHost()
		defer { host.close() }
		await host.settle()
		for clip in [Fixtures.mixed[2], Fixtures.mixed[0], Fixtures.mixed[1]] {
			let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: clip, now: Fixtures.now).label })
			host.mouse(.leftMouseDown, at: card)
			#expect(host.model.selectedID == clip.id)
			host.mouse(.leftMouseUp, at: card)
		}
		await host.settle(Int(NSEvent.doubleClickInterval * 1000) + 50)
		#expect(host.log.entries.isEmpty)
		#expect(host.model.cardsMounted)
	}

	@Test func doubleClickingACardActivatesExactlyOnce() async throws {
		let host = InputHost()
		defer { host.close() }
		await host.settle()
		let clip = Fixtures.mixed[2]
		let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: clip, now: Fixtures.now).label })
		host.click(card, count: 2)
		await host.settle(300)
		#expect(host.log.entries == ["write \(clip.id) plain=false"])
		#expect(host.model.isClosing || !host.model.cardsMounted)
	}
}

extension WindowTests.InputTests {
	@Test func printableFromResultsAndBackspaceDoNotDeleteOrCopyThePrimary() async throws {
		let host = InputHost(clips: [Fixtures.extremes[0]])
		defer { host.close() }; await host.settle(); host.focus.focus()
		let primary = host.model.selectedID
		#expect(host.model.intent == .results)
		host.key("a", code: 0)
		#expect(host.model.intent == .search && host.model.query == "a")
		host.key("\u{7f}", code: 51)
		await host.settle()
		#expect(host.model.query == "" && host.model.selectedID == primary)
		#expect(host.log.entries.isEmpty)
	}

	@Test func clickingSearchTargetsTheNativeEditorEvenWithAnEmptyQuery() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		let field = try #require(host.focus.field)
		try #require(host.model.intent == .results)
		host.trackingClick(at: field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)); await host.settle()
		#expect(host.model.intent == .search && host.model.query.isEmpty)
		#expect(host.panel.firstResponder === host.focus.editor && field.currentEditor() === host.focus.editor)
	}

	@Test func typingAfterClickingANonprimaryCardUsesTheNativeEditor() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		let clip = Fixtures.mixed[2], card = try #require(host.cards.first { $0.label.contains("Safari") })
		try #require(host.model.selectedID != clip.id)
		host.click(card, count: 1)
		#expect(host.model.selectedID == clip.id && host.model.intent == .results)
		let field = try #require(host.focus.field), editor = try #require(field.currentEditor() as? NSTextView)
		#expect(editor.isFieldEditor && host.panel.firstResponder === editor)
		host.key("a", code: 0); await host.settle()
		#expect(host.model.intent == .search && host.model.query == "a" && editor.string == "a")
		#expect(host.model.selectedID == clip.id && host.log.entries.isEmpty)
	}

	@Test func aReentrantViewUpdateCannotClearTheCharacterBeingCommitted() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle(); host.focus.focus()
		let field = try #require(host.focus.field), coordinator = try #require(field.delegate as? SearchField.Coordinator)
		let editor = try #require(field.currentEditor() as? NSTextView)
		withObservationTracking { _ = host.model.query } onChange: {
			MainActor.assumeIsolated { coordinator.synchronize(field, editor: editor) }
		}
		host.key("a", code: 0)
		#expect(host.model.query == "a" && editor.string == "a" && field.stringValue == "a")
		#expect(host.panel.firstResponder === editor)
	}

	@Test func everyKeyboardActivationSnapshotsOneTargetBeforeAnInterveningSelection() async {
		for search in [false, true] {
			for digit in [false, true] {
				for plain in [false, true] {
					let clips = Array(Fixtures.tenThousand.prefix(12)), host = InputHost(clips: clips)
					defer { host.close() }; await host.settle(); host.focus.focus()
					if search { host.key("i", code: 34) }
					let flags: NSEvent.ModifierFlags = digit ? [.command] : []
					host.key(digit ? (plain ? "@" : "2") : "\r", code: digit ? 19 : 36,
						flags: plain ? flags.union(.shift) : flags)
					host.model.applySnapshot(Array(clips.reversed()))
					host.model.select(clips[8].id)
					await host.settle()
					#expect(host.log.entries == ["write \(clips[digit ? 1 : 0].id) plain=\(plain)"])
					#expect(!host.model.cardsMounted)
				}
			}
		}
	}

	@Test func filteredResultsCommandsIncludeOffscreenPinsAndExcludeNewMatches() async {
		var clips = Array(Fixtures.tenThousand.prefix(120)); clips[100].isPinned = true
		let host = InputHost(clips: clips)
		defer { host.close() }; await host.settle(); host.focus.focus()
		host.key("1", code: 18)
		#expect(host.model.query == "1" && host.model.intent == .search)
		host.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
		#expect(host.model.intent == .results && host.model.query == "1")
		host.key("a", code: 0, flags: .command)
		let ids = clips.filter { $0.text.contains("1") }.map(\.id)
		#expect(host.model.selectedIDs == Set(ids) && ids.count > 9)
		let primary = host.model.selectedID!
		host.key("c", code: 8, flags: .command); await host.settle()
		#expect(host.log.entries == ["write \(primary) plain=false"] && host.model.cardsMounted)
		var new = clips[0]; new.id = UUID()
		host.model.applySnapshot([new] + clips)
		var deleted: [UUID] = []; let token = UUID()
		host.model.actions.delete = { deleted = $0; return token }
		host.model.actions.restore = { got in #expect(got == token); return clips.filter { deleted.contains($0.id) } }
		host.key("\u{7f}", code: 51); await host.settle()
		#expect(deleted == ids && host.model.clips.contains(new))
		host.key("z", code: 6, flags: .command); await host.settle()
		#expect(host.model.clips.count == clips.count + 1 && host.model.selectedIDs == Set(ids))
	}
}

/// Use AppKit's text/pasteboard import and export on an isolated board. No test command can use the general board.
@MainActor private final class PrivateBoardEditor: StripFieldEditor {
	let board = NSPasteboard.withUniqueName()
	override func copy(_ sender: Any?) { board.clearContents(); board.setString((string as NSString).substring(with: selectedRange()), forType: .string) }
	override func cut(_ sender: Any?) { copy(sender); delete(sender) }
	override func paste(_ sender: Any?) { breakUndoCoalescing(); if let text = board.string(forType: .string) { insertText(text, replacementRange: selectedRange()) }; breakUndoCoalescing() }
}

extension WindowTests.InputTests {
	@Test func editorCommandsUseTextSelectionClipboardAndUndoNotHistory() async throws {
		let editor = PrivateBoardEditor(), host = InputHost(focus: SearchFocus(editor: editor))
		defer { host.close(); editor.board.releaseGlobally() }; await host.settle(); host.focus.focus()
		try #require(host.panel.firstResponder === editor)
		host.key("q", code: 12)
		#expect(host.model.intent == .search && editor.string == "q")
		host.key("a", code: 0, flags: .command)
		#expect(editor.selectedRange() == NSRange(location: 0, length: 1))
		host.key("c", code: 8, flags: .command)
		#expect(editor.board.string(forType: .string) == "q")
		host.key("x", code: 7, flags: .command)
		#expect(host.model.query == "")
		await host.settle() // A real paste is a separate user event / undo group from the cut.
		host.key("v", code: 9, flags: .command)
		#expect(host.model.query == "q")
		await host.settle()
		let undo = try #require(editor.undoManager)
		#expect(undo.canUndo && editor.allowsUndo)
		host.key("z", code: 6, flags: .command)
		#expect(host.model.query == "", "native text: \(editor.string); canRedo: \(undo.canRedo)")
		host.key("b", code: 11); host.key("a", code: 0, flags: .command)
		host.key(String(UnicodeScalar(NSDeleteFunctionKey)!), code: 117)
		#expect(host.model.query == "" && host.log.entries.isEmpty)
		#expect(host.model.clips == Fixtures.mixed)
	}

	@Test func compositionFromResultsPrecedesAllCommandEquivalents() async throws {
		let host = InputHost()
		defer { host.close() }; await host.settle(); host.focus.focus()
		let editor = try #require(host.panel.firstResponder as? NSTextView), id = host.model.selectedID
		editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
		#expect(host.model.intent == .search && editor.hasMarkedText())
		for (key, code) in [("a",0),("c",8),("x",7),("v",9),("z",6),("p",35),("2",19),("@",19)] {
			let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key == "@" ? [.command,.shift] : .command,
				timestamp: 0, windowNumber: host.panel.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
				isARepeat: false, keyCode: UInt16(code))!
			// Do not forward unhandled edit equivalents to a system menu or pasteboard.
			#expect(!host.focus.handleKeyEquivalent(event, model: host.model))
		}
		host.key("\u{7f}", code: 51); await host.settle()
		#expect(host.model.clips == Fixtures.mixed && host.model.selectedID == id && host.log.entries.isEmpty)
	}

	@Test func commandPUpdatesTheSamePinTwiceAndIgnoresKeyRepeat() async throws {
		let host = InputHost()
		defer { host.close() }; await host.settle(); host.focus.focus()
		let id = Fixtures.mixed[2].id
		host.model.select(id)
		for pinned in [true, false] {
			host.key("p", code: 35, flags: .command); await host.settle()
			host.key("p", code: 35, flags: .command, repeated: true); await host.settle()
			let clip = try #require(host.model.clips.first { $0.id == id })
			#expect(clip.isPinned == pinned && host.model.selectedID == id)
			let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: clip, now: Fixtures.now).label })
			#expect(card.label.contains("Pinned") == pinned)
			#expect(card.actions.contains { $0.name == (pinned ? "Unpin" : "Pin") })
		}
	}

	@Test func secondaryClickOpensTheCardMenuWithoutSelectingOrCopying() async {
		// NSMenu dismissal stops SwiftPM's async-main run loop. Isolate native tracking; zero is *not* success.
		await #expect(processExitsWith: .exitCode(42)) {
			try await WindowTests.InputTests.checkSecondaryClick()
			exit(42)
		}
	}

	private static func checkSecondaryClick() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		let card = try #require(host.cards.first { $0.label.contains("Safari") })
		let observer = MenuProbe(), titles = Set(card.actions.map(\.name))
		try #require(titles.contains("Pin") && titles.contains("Copy"))
		NotificationCenter.default.addObserver(observer, selector: #selector(MenuProbe.began(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
		defer { NotificationCenter.default.removeObserver(observer) }
		let primary = try #require(host.model.selectedID)
		try #require(primary != Fixtures.mixed[2].id)
		host.mouse(.rightMouseDown, at: card)
		try #require(Set(observer.titles).isSuperset(of: titles))
		try #require(host.model.selectedID == primary)
		try #require(host.log.entries.isEmpty && host.model.cardsMounted)
	}

	@Test func movingToTheEndMountsTheFarSelectedCardInsideThePanel() async throws {
		let clips = Array(Fixtures.tenThousand.prefix(100))
		for reduced in [false, true] {
			let host = InputHost(clips: clips, reduced: reduced); defer { host.close() }
			host.panel.setFrameOrigin(try #require(NSScreen.main).visibleFrame.origin)
			host.panel.alphaValue = 1
			await host.settle()
			#expect(!host.cards.contains { $0.label.hasSuffix("History item 100") })
			host.model.moveToEnd(true); await host.settle(600)
			let target = try #require(host.cards.first { $0.label.hasSuffix("History item 100") })
			#expect(host.model.selectedID == clips.last?.id)
			#expect(target.frame.minX >= host.panel.frame.minX && target.frame.maxX <= host.panel.frame.maxX)
			host.model.moveToEnd(false); await host.settle(600)
			let first = try #require(host.cards.first { $0.label.hasSuffix("History item 1") })
			#expect(first.frame.minX >= host.panel.frame.minX && first.frame.maxX <= host.panel.frame.maxX)
		}
	}

	@Test func horizontalWheelMovesTheOwnedRowWithoutActivatingACard() async throws {
		let host = InputHost(clips: Array(Fixtures.tenThousand.prefix(100)))
		defer { host.close() }
		// AppKit does not scroll invisible windows. No desktop pixels are inspected.
		host.panel.setFrameOrigin(try #require(NSScreen.main).visibleFrame.origin)
		host.panel.alphaValue = 1
		await host.settle()
		let card = try #require(host.cards.first { $0.label.hasSuffix("History item 3") })
		let point = host.panel.convertPoint(fromScreen: CGPoint(x: card.frame.midX, y: card.frame.midY))
		// Start with an event addressed to this off-screen window; standalone Quartz wheels have windowNumber 0.
		let mouse = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: host.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
		let event = try #require(mouse.cgEvent)
		event.type = .scrollWheel
		event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -3)
		event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -120)
		event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -3)
		let wheel = try #require(NSEvent(cgEvent: event)), before = card.frame.minX
		let target = try #require(host.panel.contentView?.hitTest(point)), scroll = try #require(target.enclosingScrollView)
		let offset = scroll.contentView.bounds.minX
		try #require(wheel.windowNumber == host.panel.windowNumber)
		NSApp.sendEvent(wheel); await host.settle()
		#expect(scroll.contentView.bounds.minX > offset + 10)
		let after = try #require(host.cards.first { $0.label == card.label }).frame.minX
		#expect(after < before - 10)
		#expect(host.model.selectedID == Fixtures.tenThousand[0].id && host.log.entries.isEmpty)
	}
}

@MainActor private final class MenuProbe: NSObject {
	var titles: [String] = []
	@objc func began(_ note: Notification) {
		guard let menu = note.object as? NSMenu else { return }
		titles = menu.items.map(\.title)
		let stop = Timer(timeInterval: 0.02, target: menu, selector: #selector(NSMenu.cancelTrackingWithoutAnimation), userInfo: nil, repeats: false)
		RunLoop.main.add(stop, forMode: .eventTracking)
	}
}

extension WindowTests.InputTests {
	@Test func deleteKeyQueuedBeforeCloseCannotDeleteInANewPresentation() async {
		let host = InputHost(); defer { host.close() }; await host.settle(); host.focus.focus()
		host.key("\u{7f}", code: 51)
		host.model.beginClose(); host.model.open(); await host.settle()
		#expect(host.log.entries.isEmpty && host.model.clips == Fixtures.mixed && !host.model.canUndo)
	}

	@Test func emptyResultsIgnoreAllTargetedWriteAndDeleteKeys() async {
		let host = InputHost(); defer { host.close() }; await host.settle(); host.focus.focus()
		host.key("z", code: 6); host.key("z", code: 6); host.key("\t", code: 48)
		#expect(host.model.visibleClips.isEmpty)
		host.key("a", code: 0, flags: .command)
		for (key, code, flags): (String, UInt16, NSEvent.ModifierFlags) in [
			("c", 8, .command), ("1", 18, .command), ("\r", 36, []), ("\u{7f}", 51, []),
			(String(UnicodeScalar(NSDeleteFunctionKey)!), 117, [])] { host.key(key, code: code, flags: flags) }
		await host.settle()
		#expect(host.model.cardsMounted && host.model.selectedIDs.isEmpty && host.log.entries.isEmpty)
		#expect(host.model.clips == Fixtures.mixed)
	}
}
