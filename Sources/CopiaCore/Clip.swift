import Foundation

/// The six kinds of content Copia shows as cards.
public enum ClipKind: String, CaseIterable, Codable, Sendable {
	case text
	case richText
	case image
	case link
	case file
	case color
}

/// The state of a clip's saved preview image.
public enum Preview: Equatable, Sendable {
	case pending
	case ready(URL)
	case failed
}

/// A bounded, immutable snapshot of one history item, sized for display.
///
/// It never holds decoded images or the original pasteboard payload; those stay on disk.
public struct Clip: Identifiable, Equatable, Sendable {
	public var id: UUID
	public var kind: ClipKind
	/// The display text: a preview of text, a link's title or URL, or a color's hex value.
	public var text: String
	public var isCode: Bool
	public var sourceName: String?
	public var sourceBundleID: String?
	public var timestamp: Date
	/// Footer metadata such as "1,204 chars" or "2400×1600 · PNG".
	public var meta: String
	public var preview: Preview
	public var fileNames: [String]
	public var colorHex: String?
	public var url: URL?

	public init(
		id: UUID,
		kind: ClipKind,
		text: String,
		isCode: Bool = false,
		sourceName: String? = nil,
		sourceBundleID: String? = nil,
		timestamp: Date,
		meta: String = "",
		preview: Preview = .pending,
		fileNames: [String] = [],
		colorHex: String? = nil,
		url: URL? = nil
	) {
		self.id = id
		self.kind = kind
		self.text = text
		self.isCode = isCode
		self.sourceName = sourceName
		self.sourceBundleID = sourceBundleID
		self.timestamp = timestamp
		self.meta = meta
		self.preview = preview
		self.fileNames = fileNames
		self.colorHex = colorHex
		self.url = url
	}
}
