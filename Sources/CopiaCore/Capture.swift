import AppKit

/// Pure capture rules: what to keep, what kind it is, and how it is shown.
public enum Capture {
	public static let maxBytes = 20 * 1024 * 1024

	public enum Decision: Equatable, Sendable {
		case keep
		case skipEmpty
		case skipTooLarge
		case skipPrivate
		case skipIgnoredApp
	}

	/// Decides whether a change is captured. `candidates` are the apps frontmost since the last poll.
	public static func decide(types: Set<String>, draft: ClipDraft?, candidates: [String], ignoredApps: Set<String>) -> Decision {
		if !types.isDisjoint(with: PasteboardTypes.ignored) { return .skipPrivate }
		if candidates.contains(where: ignoredApps.contains) { return .skipIgnoredApp }
		guard let draft, !draft.items.isEmpty else { return .skipEmpty }
		if draft.byteSize > maxBytes { return .skipTooLarge }
		let hasNonText = draft.items.contains { item in
			item.representations.contains { $0.type != PasteboardTypes.string && $0.type != PasteboardTypes.rtf && $0.type != PasteboardTypes.html }
		}
		if !hasNonText, plainText(draft).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .skipEmpty }
		return .keep
	}

	/// Each item's text: its string, else the text of its RTF, else of its HTML.
	public static func plainText(_ draft: ClipDraft) -> String {
		draft.items.compactMap { item in
			if let data = item.data(for: PasteboardTypes.string) { return String(data: data, encoding: .utf8) }
			if let data = item.data(for: PasteboardTypes.rtf) {
				// The RTF reader is thread-safe; only the HTML importer needs the main thread.
				return NSAttributedString(rtf: data, documentAttributes: nil)?.string
					.trimmingCharacters(in: .whitespacesAndNewlines)
			}
			if let data = item.data(for: PasteboardTypes.html) { return String(data: data, encoding: .utf8).map(htmlText) }
			return nil
		}
		.joined(separator: "\n")
	}

	/// Tags dropped and common entities decoded. AppKit's HTML importer needs the main thread and WebKit, so it is not used.
	static func htmlText(_ html: String) -> String {
		var text = html.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6])[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
		text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
		for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
			text = text.replacingOccurrences(of: entity, with: char)
		}
		return text.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public static func fileURLs(_ draft: ClipDraft) -> [URL] {
		draft.items.compactMap { item in
			item.data(for: PasteboardTypes.fileURL).flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:))
		}
	}

	/// A standalone 6-digit hex value that starts with # or contains a letter A–F (so "235442" stays text).
	public static func colorHex(_ text: String) -> String? {
		let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let body = t.hasPrefix("#") ? String(t.dropFirst()) : t
		guard body.count == 6, body.allSatisfy(\.isHexDigit) else { return nil }
		guard t.hasPrefix("#") || body.contains(where: { $0.isLetter }) else { return nil }
		return "#" + body.uppercased()
	}

	public static func webURL(_ text: String) -> URL? {
		let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !t.contains(where: \.isWhitespace), let url = URL(string: t),
			let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil
		else { return nil }
		return url
	}

	/// A light heuristic: braces/semicolons and indentation on several lines.
	public static func looksLikeCode(_ text: String) -> Bool {
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
		guard lines.count >= 2 else { return false }
		let signals = lines.filter { line in
			line.hasPrefix("    ") || line.hasPrefix("\t") || line.hasSuffix("{") || line.hasSuffix("}") || line.hasSuffix(";")
				|| line.contains("func ") || line.contains("=>") || line.contains("return ")
		}
		return signals.count * 2 >= lines.count
	}

	public static func kind(of draft: ClipDraft) -> ClipKind {
		let types = Set(draft.items.flatMap { $0.representations.map(\.type) })
		if !fileURLs(draft).isEmpty { return .file }
		let text = plainText(draft)
		if colorHex(text) != nil { return .color }
		if webURL(text) != nil || (types.contains(PasteboardTypes.url) && text.isEmpty) { return .link }
		if text.isEmpty, types.contains(PasteboardTypes.png) || types.contains(PasteboardTypes.tiff) { return .image }
		if types.contains(PasteboardTypes.rtf) || types.contains(PasteboardTypes.html) { return .richText }
		if types.contains(PasteboardTypes.png) || types.contains(PasteboardTypes.tiff), text.isEmpty { return .image }
		return .text
	}

	/// Footer text, e.g. "1,204 chars", "3 files", "example.com".
	public static func meta(kind: ClipKind, text: String, files: [URL], byteSize: Int, url: URL?) -> String {
		let size = ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
		switch kind {
		case .text: return "\(text.count.formatted()) chars"
		case .richText: return "\(text.count.formatted()) chars · Rich"
		case .image: return size
		case .link: return url?.host() ?? "Link"
		case .file: return files.count == 1 ? "1 file" : "\(files.count.formatted()) files"
		case .color: return "Hex color"
		}
	}
}

/// The apps that were frontmost between two polls. Activations are logged as they happen.
public struct ActivationLog: Sendable {
	private var frontmostAtLastPoll: String?
	private var activatedSince: [String] = []

	public init(frontmost: String? = nil) { frontmostAtLastPoll = frontmost }

	public mutating func activated(_ bundleID: String) {
		activatedSince.append(bundleID)
	}

	/// Every app that could have made the copy seen at this poll. Resets the window.
	public mutating func candidatesAndReset(currentFrontmost: String?) -> [String] {
		var seen: [String] = []
		for id in [frontmostAtLastPoll].compactMap({ $0 }) + activatedSince + [currentFrontmost].compactMap({ $0 })
		where !seen.contains(id) { seen.append(id) }
		frontmostAtLastPoll = currentFrontmost
		activatedSince = []
		return seen
	}

	/// Closes the window at a poll with no copy, without asking which app is frontmost: the last activation is.
	public mutating func roll() {
		if let last = activatedSince.last { frontmostAtLastPoll = last }
		activatedSince = []
	}

	/// The source is only known when exactly one app (other than Copia) was frontmost.
	public static func source(of candidates: [String], excluding own: String?) -> String? {
		let others = candidates.filter { $0 != own }
		return others.count == 1 ? others[0] : nil
	}
}

/// How long history is kept.
public enum Retention: String, CaseIterable, Codable, Sendable {
	case day, week, month, year, forever

	public var title: String {
		switch self {
		case .day: "1 Day"
		case .week: "1 Week"
		case .month: "1 Month"
		case .year: "1 Year"
		case .forever: "Forever"
		}
	}

	/// Clips last copied before this date are pruned; `nil` keeps everything.
	public func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
		switch self {
		case .day: calendar.date(byAdding: .day, value: -1, to: now)
		case .week: calendar.date(byAdding: .day, value: -7, to: now)
		case .month: calendar.date(byAdding: .month, value: -1, to: now)
		case .year: calendar.date(byAdding: .year, value: -1, to: now)
		case .forever: nil
		}
	}
}
