import AppKit
import CopiaCore

/// Copies stored bytes to the supplied pasteboard. No destination app or file access is needed.
@MainActor
public final class Paster {
	private let pasteboard: NSPasteboard
	private let writeObjects: ([NSPasteboardItem]) -> Bool

	public init(pasteboard: NSPasteboard, writeObjects: (([NSPasteboardItem]) -> Bool)? = nil) {
		self.pasteboard = pasteboard
		self.writeObjects = writeObjects ?? { pasteboard.writeObjects($0) }
	}

	/// Prepare every item before clearing. Once cleared, the board cannot be restored if it rejects the write.
	/// With `expecting`, the write happens only while the pasteboard is still at that change count, checked right
	/// before clearing, so a copy made elsewhere is never overwritten. Returns the change count of this write.
	@discardableResult
	public func write(_ items: [PasteboardItemData], plain: Bool, expecting change: Int? = nil) throws -> Int {
		let source = Bundle.main.bundleIdentifier ?? "app.copia.Copia"
		let objects: [NSPasteboardItem] = try items.compactMap { item in
			var reps = item.representations
			if plain {
				guard let text = Self.plainText(item) else { return nil }
				reps = [(PasteboardTypes.string, Data(text.utf8))]
			}
			guard !reps.isEmpty else { return nil }
			let out = NSPasteboardItem()
			for rep in reps {
				guard out.setData(rep.data, forType: .init(rep.type)) else { throw WriteError.rejected }
			}
			guard out.setData(Data(), forType: .init(PasteboardTypes.marker)),
				out.setString(source, forType: .init(PasteboardTypes.source)) else { throw WriteError.rejected }
			return out
		}
		guard !objects.isEmpty else { throw WriteError.noRepresentations }
		if let change, pasteboard.changeCount != change { throw CancellationError() }
		let written = pasteboard.clearContents()
		guard writeObjects(objects) else { throw WriteError.rejected }
		return written
	}

	private static func plainText(_ item: PasteboardItemData) -> String? {
		let file = item.data(for: PasteboardTypes.fileURL)
		for type in [PasteboardTypes.string, PasteboardTypes.rtf, PasteboardTypes.html, PasteboardTypes.url] {
			if type == PasteboardTypes.url, file != nil { continue }
			guard let data = item.data(for: type) else { continue }
			let text = Capture.plainText(ClipDraft(items: [PasteboardItemData([(type, data)])], copiedAt: .now))
			if !text.isEmpty { return text }
		}
		// URL.path may resolve file-reference URLs. Parse the recorded path, not the current filesystem.
		guard let file, let string = String(data: file, encoding: .utf8), let components = URLComponents(string: string),
			components.scheme?.lowercased() == "file", !components.path.isEmpty else { return nil }
		return components.path
	}

	private enum WriteError: LocalizedError {
		case noRepresentations, rejected

		var errorDescription: String? {
			switch self {
			case .noRepresentations: "Nothing to copy in this format."
			case .rejected: "The clipboard rejected the copy."
			}
		}
	}
}
