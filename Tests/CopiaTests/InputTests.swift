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

	init(clips: [Clip] = Fixtures.mixed, focus: SearchFocus = SearchFocus(), reduced: Bool = false, direction: LayoutDirection = .leftToRight) {
		self.focus = focus
		model = StripModel(clips: clips)
		AccessibilityNode.enableInProcess()
		model.actions = log.actions()
		panel.host.rootView = AnyView(StripView(model: model, focus: focus, thumbnails: ThumbnailCache(), now: { Fixtures.now }, sources: .fixtures)
			.environment(\.copiaOverrides, CopiaOverrides(reduceTransparency: true, reduceMotion: reduced))
			.environment(\.layoutDirection, direction))
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

	func mouse(_ type: NSEvent.EventType, at point: CGPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []) {
		let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
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

	@Test func pointerDownMovesTheLensAndEachSingleClickCopiesWithoutClosing() async throws {
		let host = InputHost()
		defer { host.close() }
		await host.settle()
		let order = [Fixtures.mixed[2], Fixtures.mixed[0], Fixtures.mixed[1]]
		for clip in order {
			let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: clip, now: Fixtures.now).label })
			host.mouse(.leftMouseDown, at: card)
			#expect(host.model.selectedID == clip.id)
			#expect(!host.log.entries.contains("write \(clip.id) plain=false"), "copies on release, not on press")
			host.mouse(.leftMouseUp, at: card)
			await host.settle(Int(NSEvent.doubleClickInterval * 1000) + 50)
		}
		#expect(host.log.entries == order.map { "write \($0.id) plain=false" })
		#expect(host.model.cardsMounted && !host.model.isClosing)
	}

	@Test func doubleClickingACardWritesOnceAndCloses() async throws {
		let host = InputHost()
		defer { host.close() }
		await host.settle()
		let clip = Fixtures.mixed[2]
		let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: clip, now: Fixtures.now).label })
		host.click(card, count: 2)
		await host.settle(300)
		#expect(host.log.entries == ["write \(clip.id) plain=false"])
		#expect(host.model.selectedID == clip.id)
		#expect(host.model.isClosing || !host.model.cardsMounted)
	}

	@Test func aDragOrANonPrimaryReleaseOnACardDoesNotCopy() async throws {
		let host = InputHost()
		defer { host.close() }
		await host.settle()
		let card = try #require(host.cards.first { $0.label.contains("Safari") })
		let start = host.panel.convertPoint(fromScreen: CGPoint(x: card.frame.midX, y: card.frame.midY))
		host.mouse(.leftMouseDown, at: start)
		host.mouse(.leftMouseDragged, at: CGPoint(x: start.x + 40, y: start.y))
		host.mouse(.leftMouseUp, at: CGPoint(x: start.x + 40, y: start.y))
		host.mouse(.rightMouseUp, at: start)
		host.mouse(.leftMouseUp, at: start, flags: .control)
		// A drag that comes back to where it started is still a drag.
		host.mouse(.leftMouseDown, at: start)
		host.mouse(.leftMouseDragged, at: CGPoint(x: start.x + 40, y: start.y))
		host.mouse(.leftMouseDragged, at: start)
		host.mouse(.leftMouseUp, at: start)
		// A Control-modified release during a live press is not a primary click.
		host.mouse(.leftMouseDown, at: start)
		host.mouse(.leftMouseUp, at: start, flags: .control)
		// Small drags that end 8 pt from the press are a drag, even though no drag event reached 4 pt.
		host.mouse(.leftMouseDown, at: start)
		host.mouse(.leftMouseDragged, at: CGPoint(x: start.x + 3, y: start.y))
		host.mouse(.leftMouseUp, at: CGPoint(x: start.x + 8, y: start.y))
		// A short move that ends just past the card's edge does not copy.
		let edge = host.panel.convertPoint(fromScreen: CGPoint(x: card.frame.maxX - 1, y: card.frame.midY))
		host.mouse(.leftMouseDown, at: edge)
		host.mouse(.leftMouseDragged, at: CGPoint(x: edge.x + 3, y: edge.y))
		host.mouse(.leftMouseUp, at: CGPoint(x: edge.x + 3, y: edge.y))
		await host.settle(Int(NSEvent.doubleClickInterval * 1000) + 50)
		#expect(host.log.entries.isEmpty)
		#expect(host.model.cardsMounted)
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
		#expect(host.model.selectedID == clip.id && host.log.entries == ["write \(clip.id) plain=false"])
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

/// #23: the footer pin button toggles the pin without copying, closing or moving the selection.
extension WindowTests.InputTests {
	/// The centre of a card's pin slot, in panel coordinates. AX frames are bottom-left screen rects.
	func pinPoint(_ card: AXNode, in host: InputHost) -> CGPoint {
		let slot = ClipCard.pinSlot
		return host.panel.convertPoint(fromScreen: CGPoint(x: card.frame.minX + slot.midX, y: card.frame.maxY - slot.midY))
	}

	@Test func thePinButtonTogglesThePinWithoutCopyingClosingOrSelecting() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		var pins: [String] = []
		host.model.actions.setPinned = { id, pinned in pins.append("\(pinned ? "pin" : "unpin") \(id)") }
		let primary = try #require(host.model.selectedID)
		let target = try #require(host.model.clips.first { !$0.isPinned && $0.id != primary })
		func card(_ id: UUID) throws -> AXNode {
			let clip = try #require(host.model.clips.first { $0.id == id })
			return try #require(host.cards.first { $0.label == CardAccessibility(clip: clip, now: Fixtures.now).label })
		}
		// Hovering shows the outline pin on a non-primary card.
		host.model.hoveredID = target.id; await host.settle()
		var point = pinPoint(try card(target.id), in: host)
		host.mouse(.leftMouseDown, at: point); host.mouse(.leftMouseUp, at: point); await host.settle(300)
		#expect(pins == ["pin \(target.id)"])
		#expect(host.model.clips.first { $0.id == target.id }?.isPinned == true)
		#expect(host.model.selectedID == primary)
		#expect(host.log.entries.isEmpty && host.model.cardsMounted)
		// The filled pin stays visible after the pointer leaves, and clicking it unpins.
		host.model.hoveredID = nil; await host.settle()
		point = pinPoint(try card(target.id), in: host)
		host.mouse(.leftMouseDown, at: point); host.mouse(.leftMouseUp, at: point); await host.settle(300)
		#expect(pins == ["pin \(target.id)", "unpin \(target.id)"])
		#expect(host.model.clips.first { $0.id == target.id }?.isPinned == false)
		#expect(host.model.selectedID == primary && host.log.entries.isEmpty && host.model.cardsMounted)
	}

	@Test func thePrimaryCardShowsItsPinButtonWithoutHover() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		var pins: [String] = []
		host.model.actions.setPinned = { id, pinned in pins.append("\(pinned ? "pin" : "unpin") \(id)") }
		let primary = try #require(host.model.clips.first { $0.id == host.model.selectedID })
		try #require(!primary.isPinned)
		host.model.hoveredID = nil; await host.settle()
		let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: primary, now: Fixtures.now).label })
		let point = pinPoint(card, in: host)
		host.mouse(.leftMouseDown, at: point); host.mouse(.leftMouseUp, at: point); await host.settle(300)
		#expect(pins == ["pin \(primary.id)"])
		#expect(host.log.entries.isEmpty && host.model.cardsMounted)
	}

	@Test func theEmptyPinSlotOnAnUnhoveredCardIsPartOfTheCard() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		var pins = 0
		host.model.actions.setPinned = { _, _ in pins += 1 }
		let primary = try #require(host.model.selectedID)
		let target = try #require(host.model.clips.first { !$0.isPinned && $0.id != primary })
		let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: target, now: Fixtures.now).label })
		host.model.hoveredID = nil
		let point = pinPoint(card, in: host)
		host.mouse(.leftMouseDown, at: point)
		#expect(host.model.selectedID == target.id)
		host.mouse(.leftMouseUp, at: point); await host.settle(300)
		#expect(pins == 0 && host.log.entries == ["write \(target.id) plain=false"])
	}
}

extension WindowTests.InputTests {
	@Test func aLeftClickDeliveredInsideContextMenuTrackingDoesNotCopy() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		let card = try #require(host.cards.first { $0.label.contains("Safari") })
		let point = host.panel.convertPoint(fromScreen: CGPoint(x: card.frame.midX, y: card.frame.midY))
		host.panel.openContextMenu = { [unowned host] _ in
			host.mouse(.leftMouseDown, at: point); host.mouse(.leftMouseUp, at: point)
			return true
		}
		host.mouse(.rightMouseDown, at: point)
		await host.settle(Int(NSEvent.doubleClickInterval * 1000) + 50)
		#expect(host.log.entries.isEmpty && host.model.cardsMounted)
	}
}

/// Review round 3: what a press is for is decided when it starts, and kept until it ends.
extension WindowTests.InputTests {
	@Test func aPressThatStartedDuringMenuTrackingDoesNotCopyOnALaterRelease() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		let card = try #require(host.cards.first { $0.label.contains("Safari") })
		let point = host.panel.convertPoint(fromScreen: CGPoint(x: card.frame.midX, y: card.frame.midY))
		host.panel.openContextMenu = { [unowned host] _ in host.mouse(.leftMouseDown, at: point); return true }
		host.mouse(.rightMouseDown, at: point)
		host.panel.openContextMenu = nil
		host.mouse(.leftMouseUp, at: point)
		await host.settle(Int(NSEvent.doubleClickInterval * 1000) + 50)
		#expect(host.log.entries.isEmpty && host.model.cardsMounted)
	}

	@Test func pressingAnEmptyPinSlotCopiesEvenWhenSelectionRevealsThePinBeforeRelease() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		var pins = 0
		host.model.actions.setPinned = { _, _ in pins += 1 }
		let primary = try #require(host.model.selectedID)
		let target = try #require(host.model.clips.first { !$0.isPinned && $0.id != primary })
		let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: target, now: Fixtures.now).label })
		host.model.hoveredID = nil; await host.settle()
		let point = pinPoint(card, in: host)
		host.mouse(.leftMouseDown, at: point)
		await host.settle()
		#expect(host.model.selectedID == target.id)
		host.mouse(.leftMouseUp, at: point); await host.settle(300)
		#expect(pins == 0 && host.log.entries == ["write \(target.id) plain=false"])
	}

	@Test func pressingAVisiblePinNeverCopiesEvenIfSelectionHidesItBeforeRelease() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		var pins = 0
		host.model.actions.setPinned = { _, _ in pins += 1 }
		let primary = try #require(host.model.clips.first { $0.id == host.model.selectedID })
		try #require(!primary.isPinned)
		host.model.hoveredID = nil; await host.settle()
		let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: primary, now: Fixtures.now).label })
		let point = pinPoint(card, in: host)
		host.mouse(.leftMouseDown, at: point)
		host.model.move(1); await host.settle()
		host.mouse(.leftMouseUp, at: point); await host.settle(300)
		#expect(host.log.entries.isEmpty && host.model.cardsMounted)
	}
}

/// Review round 4: the pin follows the layout direction, and a pin click never starts a card double-click.
extension WindowTests.InputTests {
	@Test func aRightToLeftHostStillLaysTheStripOutLeftToRightWithThePinOnTheRight() async throws {
		let host = InputHost(direction: .rightToLeft); defer { host.close() }; await host.settle()
		var pins = 0
		host.model.actions.setPinned = { _, _ in pins += 1 }
		let primary = try #require(host.model.clips.first { $0.id == host.model.selectedID })
		host.model.hoveredID = nil; await host.settle()
		let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: primary, now: Fixtures.now).label })
		#expect(host.panel.frame.contains(CGPoint(x: card.frame.midX, y: card.frame.midY)), "newest card stays at the left, inside the panel")
		let point = pinPoint(card, in: host)
		host.mouse(.leftMouseDown, at: point); host.mouse(.leftMouseUp, at: point); await host.settle(300)
		#expect(pins == 1 && host.log.entries.isEmpty)
	}

	@Test func aCardClickRightAfterAPinClickIsASingleClick() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		var pins = 0
		host.model.actions.setPinned = { _, _ in pins += 1 }
		let primary = try #require(host.model.clips.first { $0.id == host.model.selectedID })
		host.model.hoveredID = nil; await host.settle()
		let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: primary, now: Fixtures.now).label })
		let pin = pinPoint(card, in: host), beside = CGPoint(x: pin.x - 16, y: pin.y)
		host.mouse(.leftMouseDown, at: pin, count: 1); host.mouse(.leftMouseUp, at: pin, count: 1)
		host.mouse(.leftMouseDown, at: beside, count: 2); host.mouse(.leftMouseUp, at: beside, count: 2)
		await host.settle(300)
		#expect(pins == 1)
		#expect(host.log.entries == ["write \(primary.id) plain=false"])
		#expect(host.model.cardsMounted && !host.model.isClosing)
	}
}

/// #26: arrows in Results move the lens and the clipboard follows; ⎋ restores; arrows in Search edit text.
extension WindowTests.InputTests {
	static let home = (String(UnicodeScalar(NSHomeFunctionKey)!), UInt16(115))
	static let end = (String(UnicodeScalar(NSEndFunctionKey)!), UInt16(119))
	static let escapeKey = ("\u{1b}", UInt16(53))
	var settleMs: Int { Int(StripModel.browseSettle.components.attoseconds / 1_000_000_000_000_000) + 250 }

	@Test func arrowKeysInResultsCopyWhereTheLensRestsAndKeepTheStripOpen() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle(); host.focus.focus()
		host.key(Self.rightArrow.0, code: Self.rightArrow.1)
		host.key(Self.rightArrow.0, code: Self.rightArrow.1)
		await host.settle(settleMs)
		#expect(host.model.selectedID == Fixtures.mixed[2].id)
		#expect(host.log.entries == ["write \(Fixtures.mixed[2].id) plain=false"])
		#expect(host.model.lensOnClipboard && host.model.cardsMounted)
		host.key(Self.leftArrow.0, code: Self.leftArrow.1)
		await host.settle(settleMs)
		#expect(host.log.entries.last == "write \(Fixtures.mixed[1].id) plain=false")
	}

	@Test func homeAndEndJumpAndCopy() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle(); host.focus.focus()
		host.key(Self.end.0, code: Self.end.1)
		await host.settle(settleMs)
		#expect(host.model.selectedID == Fixtures.mixed.last!.id)
		host.key(Self.home.0, code: Self.home.1)
		await host.settle(settleMs)
		#expect(host.model.selectedID == Fixtures.mixed[0].id)
		#expect(host.log.entries == ["write \(Fixtures.mixed.last!.id) plain=false", "write \(Fixtures.mixed[0].id) plain=false"])
	}

	@Test func arrowKeysInSearchBrowseTheMatchesAndKeepTheQuery() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle(); host.focus.focus()
		host.key("r", code: 15); host.key("e", code: 14)
		await host.settle()
		try #require(host.model.intent == .search && host.model.query == "re")
		let matches = host.model.visibleClips.map(\.id)
		try #require(matches.count >= 3)
		host.key(Self.rightArrow.0, code: Self.rightArrow.1)
		host.key(Self.rightArrow.0, code: Self.rightArrow.1)
		host.key(Self.leftArrow.0, code: Self.leftArrow.1)
		await host.settle(settleMs)
		#expect(host.model.selectedID == matches[1])
		#expect(host.log.entries == ["write \(matches[1]) plain=false"])
		#expect(host.model.lensOnClipboard)
		host.key(Self.end.0, code: Self.end.1)
		await host.settle(settleMs)
		#expect(host.model.selectedID == matches.last)
		host.key(Self.home.0, code: Self.home.1)
		await host.settle(settleMs)
		#expect(host.model.selectedID == matches[0])
		#expect(host.log.entries == ["write \(matches[1]) plain=false", "write \(matches.last!) plain=false", "write \(matches[0]) plain=false"])
		// Still searching: the query is intact and ⌫ edits it, never a card.
		#expect(host.model.intent == .search && host.model.query == "re")
		host.key("\u{7f}", code: 51)
		await host.settle()
		#expect(host.model.query == "r")
		#expect(host.log.entries.count == 3 && host.model.clips.count == Fixtures.mixed.count)
	}

	@Test func modifiedArrowsInSearchStillEditTheText() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle(); host.focus.focus()
		host.key("a", code: 0); host.key("b", code: 11)
		await host.settle()
		let editor = try #require(host.panel.firstResponder as? NSTextView)
		let selection = host.model.selectedID
		let keys: [((String, UInt16), NSEvent.ModifierFlags)] = [(Self.leftArrow, .shift), (Self.leftArrow, .option), (Self.rightArrow, [.shift, .option])]
		for (arrow, flags) in keys {
			for type in [NSEvent.EventType.keyDown, .keyUp] {
				let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags.union([.function, .numericPad]),
					timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.panel.windowNumber, context: nil,
					characters: arrow.0, charactersIgnoringModifiers: arrow.0, isARepeat: false, keyCode: arrow.1)!
				host.panel.sendEvent(event)
			}
		}
		await host.settle(settleMs)
		#expect(host.model.selectedID == selection && host.log.entries.isEmpty)
		#expect(host.model.query == "ab" && editor.selectedRange().length > 0, "⇧⌥ arrows select text")
	}

	@Test func commandArrowsInSearchMoveTheCaretNotTheCards() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle(); host.focus.focus()
		host.key("a", code: 0); host.key("b", code: 11)
		await host.settle()
		let editor = try #require(host.panel.firstResponder as? NSTextView)
		let selection = host.model.selectedID
		for (arrow, caret) in [(Self.leftArrow, 0), (Self.rightArrow, 2)] {
			for type in [NSEvent.EventType.keyDown, .keyUp] {
				let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.command, .function, .numericPad],
					timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.panel.windowNumber, context: nil,
					characters: arrow.0, charactersIgnoringModifiers: arrow.0, isARepeat: false, keyCode: arrow.1)!
				host.panel.sendEvent(event)
			}
			await host.settle()
			#expect(editor.selectedRange() == NSRange(location: caret, length: 0))
		}
		await host.settle(settleMs)
		#expect(host.model.selectedID == selection && host.log.entries.isEmpty && host.model.intent == .search)
	}

	@Test func losingKeyFocusKeepsTheCardTheUserArrowedTo() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle(); host.focus.focus()
		var closed = false
		let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: host.panel, queue: .main) { _ in
			MainActor.assumeIsolated { closed = true; host.model.beginClose() }
		}
		defer { NotificationCenter.default.removeObserver(observer) }
		host.key(Self.rightArrow.0, code: Self.rightArrow.1)
		// Another window takes key before the lens rests, as clicking into an app or opening Settings does.
		let other = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
		other.isReleasedWhenClosed = false
		other.makeKeyAndOrderFront(nil)
		defer { other.orderOut(nil) }
		await host.settle(settleMs)
		#expect(closed)
		#expect(host.log.entries == ["write \(Fixtures.mixed[1].id) plain=false"])
	}

	@Test func escapeAfterArrowingRestoresTheOpenTimeCard() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle()
		host.panel.hide(); host.model.beginClose(); await host.settle()
		let a = Fixtures.mixed[0].id
		host.model.open(clipboard: ClipboardCard(id: a)); host.panel.orderFrontRegardless(); host.panel.makeKey()
		host.model.animateIn(); await host.settle(); host.focus.focus()
		host.key(Self.rightArrow.0, code: Self.rightArrow.1)
		await host.settle(settleMs)
		#expect(host.model.restoreHint == .restore)
		host.key(Self.escapeKey.0, code: Self.escapeKey.1)
		await host.settle(settleMs)
		#expect(host.log.entries == ["write \(Fixtures.mixed[1].id) plain=false", "write \(a) plain=false"])
		#expect(host.model.selectedID == a && !host.model.cardsMounted)
	}
}

/// #26 in the window: ⌘→ routing, the lens fill, and VoiceOver's "On clipboard".
extension WindowTests.InputTests {
	@Test func commandArrowsJumpThroughTheFieldEditorAndCopy() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle(); host.focus.focus()
		for (arrow, expected) in [(Self.rightArrow, Fixtures.mixed.last!.id), (Self.leftArrow, Fixtures.mixed[0].id)] {
			for type in [NSEvent.EventType.keyDown, .keyUp] {
				let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.command, .function, .numericPad],
					timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.panel.windowNumber, context: nil,
					characters: arrow.0, charactersIgnoringModifiers: arrow.0, isARepeat: false, keyCode: arrow.1)!
				host.panel.sendEvent(event)
			}
			await host.settle(settleMs)
			#expect(host.model.selectedID == expected)
		}
		#expect(host.log.entries == ["write \(Fixtures.mixed.last!.id) plain=false", "write \(Fixtures.mixed[0].id) plain=false"])
	}

	@Test func voiceOverHearsWhichCardIsOnTheClipboard() async throws {
		let host = InputHost(); defer { host.close() }; await host.settle(); host.focus.focus()
		host.key(Self.rightArrow.0, code: Self.rightArrow.1)
		await host.settle(settleMs)
		let on = host.cards.filter { $0.valueDescription == "On clipboard" }
		#expect(on.count == 1 && on.first?.label == CardAccessibility(clip: Fixtures.mixed[1], now: Fixtures.now).label)
	}
}

extension WindowTests.LensTests {
	@Test func theLensIsAccentOnTheClipboardCardAndGreyOtherwise() async throws {
		let host = InputHost(); defer { host.close() }
		host.panel.setFrameOrigin(try #require(NSScreen.main).visibleFrame.origin); host.panel.alphaValue = 1
		host.model.beginClose(); await host.settle()
		host.model.open(clipboard: ClipboardCard(id: Fixtures.mixed[0].id)); host.panel.orderFrontRegardless(); host.model.animateIn()
		await host.settle(400)
		let v = host.panel.host
		func ringRect(_ clip: Clip) throws -> CGRect {
			let card = try #require(host.cards.first { $0.label == CardAccessibility(clip: clip, now: Fixtures.now).label })
			return CGRect(x: card.frame.midX - host.panel.frame.minX - Theme.cardSize.width / 2,
				y: host.panel.frame.maxY - card.frame.midY - Theme.cardSize.height / 2,
				width: Theme.cardSize.width, height: Theme.cardSize.height).insetBy(dx: -Theme.lensOutset, dy: -Theme.lensOutset)
		}
		/// The ring's weakest edge against its halo, its color in the middle of the top edge, and the card's own
		/// surface in the empty middle of the footer.
		func ring(_ clip: Clip) throws -> (contrast: Double, color: SIMD3<Double>, surface: SIMD3<Double>) {
			let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
			v.cacheDisplay(in: v.bounds, to: rep)
			let image = try #require(rep.cgImage), rect = try ringRect(clip), scale = CGFloat(image.width) / v.bounds.width
			let contrast = ContrastCheck.lens(in: ContrastCheck.Bitmap(image), ring: rect, scale: scale)
			func sample(_ x: CGFloat, _ y: CGFloat) throws -> SIMD3<Double> {
				let c = try #require(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
				return SIMD3(c.redComponent, c.greenComponent, c.blueComponent)
			}
			let footer = rect.maxY - Theme.lensOutset - Theme.footerHeight / 2
			return (contrast, try sample(rect.midX, rect.minY + 1.5), try sample(rect.midX + 20, footer))
		}
		var accent = SIMD3<Double>(0, 0, 0)
		v.effectiveAppearance.performAsCurrentDrawingAppearance {
			let c = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
			accent = SIMD3(c.redComponent, c.greenComponent, c.blueComponent)
		}
		func chroma(_ c: SIMD3<Double>) -> Double { c.max() - c.min() }
		let copied = try ring(Fixtures.mixed[0])
		#expect(copied.contrast > 2, "on the clipboard: an unbroken ring")
		host.model.move(1); await host.settle(400)
		#expect(!host.model.lensOnClipboard)
		let selected = try ring(Fixtures.mixed[1])
		#expect(selected.contrast > 2, "only selected: an unbroken ring too")
		#expect(chroma(selected.color) < 0.06, "only selected: grey \(selected.color)")
		// A grey (Graphite) accent can't be told apart by hue; the tint and the top-bar chip carry it then.
		#expect(chroma(selected.surface) < 0.01, "only selected: the card keeps its plain surface \(selected.surface)")
		if chroma(accent) > 0.3 {
			#expect(chroma(copied.color) > 0.3, "on the clipboard: the accent \(copied.color)")
			#expect(chroma(copied.surface) > 0.025, "on the clipboard: the card itself takes a light accent wash \(copied.surface)")
		}
	}
}
