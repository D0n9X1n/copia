import Testing
import AppKit
import CopiaCore
import CopiaFixtures
import CopiaSystem
@testable import CopiaUI

extension WindowTests {
	/// End-to-end strip commands with the production writer, recorded bytes, and a unique pasteboard.
	@MainActor @Suite struct StripCopyTests {}
}

extension WindowTests.StripCopyTests {
	var items: [PasteboardItemData] { [
		PasteboardItemData([(PasteboardTypes.string, Data("text".utf8))]),
		PasteboardItemData([(PasteboardTypes.rtf, Data(#"{\rtf1\ansi Rich}"#.utf8))]),
		PasteboardItemData([(PasteboardTypes.png, Data([137, 80, 78, 71]))]),
		PasteboardItemData([(PasteboardTypes.url, Data("https://example.invalid/test".utf8))]),
		PasteboardItemData([(PasteboardTypes.fileURL, Data("file:///fixture/never-opened.txt".utf8))]),
	] }

	@Test func activationRoutesWriteOrderedItemsWithMarkersToPrivateBoard() async throws {
		for route in ["Return", "Shift-Return", "Cmd-1", "Shift-Cmd-1", "Cmd-C", "Double-click", "AX activation", "AX plain", "AX copy"] {
			let host = InputHost(), board = NSPasteboard.withUniqueName(), writer = Paster(pasteboard: board)
			defer { host.close(); board.releaseGlobally() }; await host.settle(); host.focus.focus()
			var fetched: [UUID] = []
			host.model.actions.write = { id, plain in fetched.append(id); try writer.write(items, plain: plain) }
			let clip = Fixtures.mixed[0], card = try #require(host.cards.first { $0.label == CardAccessibility(clip: clip, now: Fixtures.now).label })
			switch route {
			case "Return", "Shift-Return": host.key("\r", code: 36, flags: route == "Return" ? [] : .shift)
			case "Cmd-1", "Shift-Cmd-1": host.key(route == "Cmd-1" ? "1" : "!", code: 18, flags: route == "Cmd-1" ? .command : [.command, .shift])
			case "Cmd-C": host.key("c", code: 8, flags: .command)
			case "Double-click": host.click(card, count: 2)
			default:
				let action: CardAction = route == "AX copy" ? .copy : route == "AX plain" ? .copyPlain : .activate
				let ax = try #require(card.actions.first { $0.name == action.rawValue })
				if let handler = ax.handler { _ = handler() }
				else if let target = ax.target as? NSObject, let selector = ax.selector { _ = target.perform(selector, with: ax) }
			}
			await host.settle()
			let written = try #require(board.pasteboardItems)
			#expect(fetched == [clip.id], "\(route)")
			#expect(host.model.cardsMounted == (route == "Cmd-C" || route == "AX copy"), "\(route)")
			#expect(written.allSatisfy { $0.data(forType: .init(PasteboardTypes.marker)) != nil && $0.string(forType: .init(PasteboardTypes.source)) != nil })
			if route.contains("Shift") || route == "AX plain" {
				#expect(written.map { $0.string(forType: .string) } == ["text", "Rich", "https://example.invalid/test", "/fixture/never-opened.txt"])
				#expect(written.allSatisfy { !$0.types.contains(.rtf) && !$0.types.contains(.fileURL) })
			} else {
				try #require(written.count == items.count)
				for (output, input) in zip(written, items) {
					for rep in input.representations { #expect(output.data(forType: .init(rep.type)) == rep.data) }
				}
			}
		}
	}

	@Test func voiceOverPinAndUnpinPersistAndUpdateTheVisibleCardAction() async throws {
		let rig = try AppRig(), model = rig.controller.model, panel = rig.controller.panel
		try await rig.copy("AX pin fixture")
		let key = try #require(try await rig.controller.store.recent().first?.key)
		AccessibilityNode.enableInProcess()
		panel.alphaValue = 0
		panel.setFrame(CGRect(x: -6000, y: -6000, width: 1000, height: Theme.panelHeight), display: false)
		model.open(); panel.orderFrontRegardless(); model.animateIn()
		defer { model.beginClose(); panel.orderOut(nil) }
		func card() -> AXNode? {
			panel.host.layoutSubtreeIfNeeded()
			return AXNode(panel.host).all.first { !$0.actions.isEmpty && $0.label.hasSuffix("AX pin fixture") }
		}
		for pinned in [true, false] {
			let actionName = pinned ? "Pin" : "Unpin", next = pinned ? "Unpin" : "Pin"
			try #require(await eventually { card()?.actions.contains { $0.name == actionName } == true })
			let ax = try #require(card()?.actions.first { $0.name == actionName })
			if let handler = ax.handler { _ = handler() }
			else if let target = ax.target as? NSObject, let selector = ax.selector { _ = target.perform(selector, with: ax) }
			try #require(try await eventually { try await rig.controller.store.fetch(key)?.isPinned == pinned })
			try #require(await eventually { card()?.actions.contains { $0.name == next } == true })
			let updated = try #require(card())
			#expect(updated.label.hasPrefix("Pinned, ") == pinned)
			#expect(updated.isSelected && !updated.actions.contains { $0.name == actionName })
			#expect(model.cardsMounted && model.clips.first?.isPinned == pinned)
		}
	}

	@Test func missingPayloadRejectedWriteAndUnconvertibleImageLeaveStripOpenWithError() async throws {
		for failure in ["missing", "rejected", "image"] {
			let host = InputHost(), board = NSPasteboard.withUniqueName()
			defer { host.close(); board.releaseGlobally() }; await host.settle(); host.focus.focus()
			board.setString("untouched", forType: .string)
			var writes = 0
			let writer = Paster(pasteboard: board) { objects in
				writes += 1
				return failure != "rejected" && board.writeObjects(objects)
			}
			host.model.actions.write = { _, plain in
				if failure == "missing" { throw CocoaError(.fileNoSuchFile) }
				try writer.write(failure == "image" ? [items[2]] : items, plain: plain)
			}
			host.key("\r", code: 36, flags: failure == "image" ? .shift : []); await host.settle()
			#expect(writes == (failure == "rejected" ? 1 : 0))
			#expect(host.model.cardsMounted && host.model.closeCount == 0, "\(failure)")
			if case .error = host.model.toast {} else { Issue.record("Missing error for \(failure)") }
			if failure != "rejected" { #expect(board.string(forType: .string) == "untouched") }
		}
	}
}
