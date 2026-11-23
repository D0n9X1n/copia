import AppKit
import SwiftUI

/// The editor stays first responder even when commands target results. AppKit owns all text and IME input.
@MainActor
public final class SearchFocus {
	weak var field: NSTextField?
	let editor: StripFieldEditor

	public convenience init() { self.init(editor: StripFieldEditor()) }
	init(editor: StripFieldEditor) {
		self.editor = editor
		editor.isFieldEditor = true
		editor.allowsUndo = true
		// Search is literal input, not prose. Do not let automatic replacements rewrite a query or IME candidate.
		editor.isRichText = false
		editor.isAutomaticTextCompletionEnabled = false
		editor.isAutomaticSpellingCorrectionEnabled = false
		editor.isAutomaticTextReplacementEnabled = false
	}

	public func focus() {
		guard let field, let window = field.window else { return }
		if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
	}

	public func handleKeyEquivalent(_ event: NSEvent, model: StripModel) -> Bool {
		let flags = event.modifierFlags
		guard model.cardsMounted, !model.isClosing, !editor.hasMarkedText(), flags.contains(.command),
			flags.intersection([.option, .control]).isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
		let shifted = flags.contains(.shift)
		let digits = shifted && "!@#$%^&*(".contains(key) ? "!@#$%^&*(" : "123456789"
		if key.count == 1, let character = key.first, let index = digits.firstIndex(of: character) {
			let slot = digits.distance(from: digits.startIndex, to: index), clips = model.visibleClips
			if clips.indices.contains(slot) { model.requestCopy(id: clips[slot].id, plain: shifted, dismiss: true) }
			return true
		}
		if model.intent == .search {
			switch (key, shifted) {
			case ("a", false): editor.selectAll(nil)
			case ("c", false): editor.copy(nil)
			case ("x", false): editor.cut(nil)
			case ("v", false): editor.paste(nil)
			case ("z", false): editor.undoManager?.undo()
			case ("z", true): editor.undoManager?.redo()
			default: return false
			}
			return true
		}
		guard !shifted else { return false }
		switch key {
		case "a": model.selectAllResults()
		case "c": model.requestCopy(id: model.selectedID, plain: false, dismiss: false)
		case "z": model.request { await model.undo() }
		case "p": if let id = model.selectedID, !event.isARepeat { model.request { await model.togglePin(id) } }
		default: return false
		}
		return true
	}
}

/// Capture intent at the two native input boundaries, *before* the insertion or first marked range.
class StripFieldEditor: NSTextView {
	weak var model: StripModel?
	private(set) var keyModifiers: NSEvent.ModifierFlags = []

	/// Plain ← → Home End: while one is down the clipboard waits, so a held arrow writes once, where it stops.
	/// ⌘ arrows jump once (AppKit may swallow their release), and ⇧ ⌥ ⌃ arrows edit text, so neither holds the clipboard.
	static let browseKeys: Set<UInt16> = [123, 124, 115, 119]
	static func holdsBrowse(_ event: NSEvent) -> Bool {
		browseKeys.contains(event.keyCode) && event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
	}

	override func keyDown(with event: NSEvent) {
		keyModifiers = event.modifierFlags
		defer { keyModifiers = [] }
		if Self.holdsBrowse(event), !hasMarkedText() { model?.browseKey(event.keyCode, down: true) }
		super.keyDown(with: event)
	}
	override func keyUp(with event: NSEvent) {
		// Any release of the key ends its hold, whatever modifiers are down by then.
		if Self.browseKeys.contains(event.keyCode) { model?.browseKey(event.keyCode, down: false) }
		super.keyUp(with: event)
	}
	override func insertText(_ string: Any, replacementRange: NSRange) {
		model?.intent = .search
		super.insertText(string, replacementRange: replacementRange)
	}
	override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
		model?.intent = .search
		super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
	}
	override func mouseDown(with event: NSEvent) {
		model?.intent = .search
		super.mouseDown(with: event)
	}
}

private final class SearchCell: NSTextFieldCell {
	var editor: StripFieldEditor?
	override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

private final class StripTextField: NSTextField {
	override func mouseDown(with event: NSEvent) {
		(cell as? SearchCell)?.editor?.model?.intent = .search
		super.mouseDown(with: event)
	}
}

/// A native text field so typing, input methods and the field editor all behave normally.
/// Strip commands defer to the native field editor while an input method has marked text.
struct SearchField: NSViewRepresentable {
	@Bindable var model: StripModel
	let focus: SearchFocus

	func makeCoordinator() -> Coordinator { Coordinator(model: model) }

	func makeNSView(context: Context) -> NSTextField {
		let field = StripTextField()
		let cell = SearchCell(textCell: "")
		cell.editor = focus.editor
		field.cell = cell
		field.isEditable = true
		field.isSelectable = true
		focus.editor.model = model
		field.isBordered = false
		field.drawsBackground = false
		field.focusRingType = .none
		field.font = .systemFont(ofSize: 15)
		// Glass metadata ink: the system placeholder color falls below 4.5:1 on the glass.
		field.placeholderAttributedString = NSAttributedString(string: "Type to search",
			attributes: [.foregroundColor: Theme.glassInk2NS, .font: NSFont.systemFont(ofSize: 15)])
		field.delegate = context.coordinator
		field.cell?.isScrollable = true
		field.cell?.wraps = false
		field.setAccessibilityLabel("Search clipboard history")
		focus.field = field
		return field
	}

	func updateNSView(_ field: NSTextField, context: Context) {
		context.coordinator.model = model
		context.coordinator.synchronize(field, editor: focus.editor)
	}

	@MainActor
	final class Coordinator: NSObject, NSTextFieldDelegate {
		var model: StripModel
		var syncedQuery: String?
		init(model: StripModel) { self.model = model }

		func synchronize(_ field: NSTextField, editor: NSTextView) {
			// A field editor can have a transient uncommitted value even between native IME callbacks.
			// Only push an actual model change; an unrelated view update must not clear that value.
			if syncedQuery != model.query, !editor.hasMarkedText() {
				syncedQuery = model.query
				if field.stringValue != model.query { field.stringValue = model.query }
			}
		}

		func controlTextDidChange(_ note: Notification) {
			guard let field = note.object as? NSTextField else { return }
			let committed = field.stringValue
			// Observation can synchronously refresh the field before the model setter stores its new value.
			model.query = committed
			syncedQuery = committed
		}

		func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
			guard !textView.hasMarkedText() else { return false }
			let shift = (textView as? StripFieldEditor)?.keyModifiers.contains(.shift) ?? false
			let results = model.intent == .results
			// Plain ← → and Home End browse the cards in Search too; ⌘ ⌥ ⇧ arrows keep editing the query.
			switch selector {
			case #selector(NSResponder.moveLeft(_:)): model.browse(-1)
			case #selector(NSResponder.moveRight(_:)): model.browse(1)
			case #selector(NSResponder.scrollToBeginningOfDocument(_:)): model.browseToEnd(false)
			case #selector(NSResponder.scrollToEndOfDocument(_:)): model.browseToEnd(true)
			case #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToLeftEndOfLine(_:)):
				guard results else { return false }; model.browseToEnd(false)
			case #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)):
				guard results else { return false }; model.browseToEnd(true)
			case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
				model.requestCopy(id: model.selectedID, plain: shift, dismiss: true)
			case #selector(NSResponder.cancelOperation(_:)): model.escape()
			case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveDown(_:)):
				model.intent = .results
			case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
				guard results else { return false }
				let ids = model.selectedIDs
				model.request { [model] in await model.delete(ids: ids) }
			default: return false
			}
			return true
		}
	}
}
