import AppKit
import SwiftUI
import CopiaCore

/// How a card lays out one clip. The view reads exactly this, so tests check what users see.
struct CardPresentation {
	let clip: Clip
	var size: CGSize { Theme.cardSize }
	var headerHeight: CGFloat { Theme.headerHeight }
	var bodyHeight: CGFloat { Theme.bodyHeight }
	var footerHeight: CGFloat { Theme.footerHeight }

	var typeLabel: String {
		switch clip.kind {
		case .text: clip.isCode ? "Code" : "Text"
		case .richText: "Rich Text"
		case .image: "Image"
		case .link: "Link"
		case .file: clip.fileNames.count > 1 ? "Files" : "File"
		case .color: "Color"
		}
	}

	var symbol: String {
		switch clip.kind {
		case .text: clip.isCode ? "chevron.left.forwardslash.chevron.right" : "doc.text"
		case .richText: "doc.richtext"
		case .image: "photo"
		case .link: "link"
		case .file: "doc"
		case .color: "paintpalette"
		}
	}

	/// Body text lines: 9 for code, 8 otherwise.
	var lineLimit: Int { clip.isCode ? 9 : 8 }
	/// Text truncates at the tail; file names in the middle.
	var textTruncation: Text.TruncationMode { .tail }
	var fileNameTruncation: Text.TruncationMode { .middle }
	/// A pending preview shows the kind symbol at 30% so a card is never blank.
	var placeholderOpacity: Double { 0.30 }

	/// What a card without its preview shows: the symbol plus a filename or URL.
	var fallback: String? {
		guard clip.preview == .failed else { return nil }
		return clip.url?.absoluteString ?? clip.fileNames.first ?? clip.text
	}

	var footer: String { clip.meta }
}

/// One history card: 216×232, header 40 / body 164 / footer 28.
struct ClipCard: View {
	let clip: Clip
	let tint: Theme.Tint
	let icon: NSImage?
	let badge: Int?
	let hovered: Bool
	let selected: Bool
	let removing: Bool
	let now: Date
	let highlight: String
	let thumbnails: ThumbnailCache

	@Environment(\.colorSchemeContrast) private var contrast
	@Environment(\.colorScheme) private var scheme
	@Environment(\.copiaOverrides) private var overrides
	private var highContrast: Bool { overrides.highContrast ?? (contrast == .increased) }
	private var p: CardPresentation { CardPresentation(clip: clip) }

	var body: some View {
		VStack(spacing: 0) {
			header
			CardBody(clip: clip, presentation: p, highContrast: highContrast, highlight: highlight, thumbnails: thumbnails)
				.frame(width: Theme.cardSize.width, height: Theme.bodyHeight)
			footer
		}
		.frame(width: Theme.cardSize.width, height: Theme.cardSize.height)
		.background(Theme.card)
		.clipShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
				.strokeBorder(Theme.stroke(hovered: hovered, highContrast: highContrast), lineWidth: 1)
		}
		.shadow(color: .black.opacity(selected ? 0.18 : (scheme == .dark ? 0.30 : 0.10)),
			radius: selected ? 9 : 4, y: selected ? 6 : 2)
		.scaleEffect(removing ? 0.9 : 1)
		.opacity(removing ? 0 : 1)
	}

	private var header: some View {
		HStack(spacing: 8) {
			Group {
				if let icon {
					Image(nsImage: icon).resizable().interpolation(.high)
				} else {
					Image(systemName: "questionmark.app.dashed").resizable().scaledToFit().foregroundStyle(Theme.ink.opacity(0.5)).padding(1)
				}
			}
			.frame(width: 20, height: 20)
			Text(p.typeLabel)
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(Theme.ink)
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer(minLength: 4)
			Text(Self.relative(clip.timestamp, now: now))
				.font(.system(size: 11, weight: .medium).monospacedDigit())
				.foregroundStyle(Theme.ink)
				.lineLimit(1)
		}
		.padding(.horizontal, 12)
		.frame(height: Theme.headerHeight)
		.frame(maxWidth: .infinity)
		.background(tint.band)
	}

	private var footer: some View {
		HStack(spacing: 6) {
			Text(p.footer)
				.font(.system(size: 11, weight: .medium).monospacedDigit())
				.foregroundStyle(Theme.ink2(highContrast: highContrast))
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer(minLength: 4)
			if let badge {
				Text("⌘\(badge)")
					.font(.system(size: 10, weight: .semibold).monospacedDigit())
					.foregroundStyle(Theme.ink)
					.frame(minWidth: 20, minHeight: 20)
					.padding(.horizontal, 2)
					.background(Theme.field, in: .rect(cornerRadius: Theme.smallRadius, style: .continuous))
					.transition(.opacity.combined(with: .scale(scale: 0.8)))
			}
		}
		.padding(.horizontal, 12)
		.frame(height: Theme.footerHeight)
	}

	static func relative(_ date: Date, now: Date) -> String {
		let seconds = max(0, now.timeIntervalSince(date))
		switch seconds {
		case ..<60: return "Now"
		case ..<3_600: return "\(Int(seconds / 60))m"
		case ..<86_400: return "\(Int(seconds / 3_600))h"
		case ..<172_800: return "Yesterday"
		default: return "\(Int(seconds / 86_400))d"
		}
	}
}

/// The 164 pt body, drawn per kind.
private struct CardBody: View {
	let clip: Clip
	let presentation: CardPresentation
	let highContrast: Bool
	let highlight: String
	let thumbnails: ThumbnailCache
	/// Bumped when a background decode lands; the image itself lives only in the size-limited cache.
	@State private var decoded = 0

	private var previewURL: URL? {
		if case let .ready(url) = clip.preview { return url }
		return nil
	}

	/// The thumbnail if the cache holds it. Cards never keep their own copy, so the 24 MB cap is the real cap.
	private var thumbnail: NSImage? {
		_ = decoded
		return previewURL.flatMap(thumbnails.cached)
	}

	var body: some View {
		// Decide from what this body drew, not the cache now: a decode can land between the two, and then nothing redraws.
		let shown = thumbnail != nil
		content
			.task(id: previewURL) {
				guard let url = previewURL, !shown else { return }
				guard await thumbnails.load(url) != nil else { return }
				withAnimation(.linear(duration: 0.15)) { decoded += 1 }
			}
	}

	@ViewBuilder private var content: some View {
		switch clip.kind {
		case .text, .richText: textBody
		case .image: imageBody
		case .link: linkBody
		case .file: fileBody
		case .color: colorBody
		}
	}

	@ViewBuilder private var textBody: some View {
		if clip.isCode { codeBody } else { proseBody }
	}

	private var codeBody: some View {
		VStack(alignment: .leading, spacing: 3) {
			ForEach(Array(clip.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(presentation.lineLimit).enumerated()), id: \.offset) { _, line in
				Text(highlighted(String(line.prefix(120)).replacingOccurrences(of: "\t", with: "    ")))
					.font(.system(size: 12, design: .monospaced))
					.foregroundStyle(Theme.ink)
					.lineLimit(1)
					.truncationMode(presentation.textTruncation)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.padding(12)
		.mask {
			LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82),
				.init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
		}
	}

	private var proseBody: some View {
		Text(highlighted(String(clip.text.prefix(600))))
			.font(.system(size: 13))
			.lineSpacing(4)
			.foregroundStyle(Theme.ink)
			.lineLimit(presentation.lineLimit)
			.truncationMode(presentation.textTruncation)
			.multilineTextAlignment(.leading)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			.padding(12)
			.mask {
				LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82),
					.init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
			}
	}

	private func highlighted(_ text: String) -> AttributedString {
		var attributed = AttributedString(text)
		let q = highlight.trimmingCharacters(in: .whitespaces)
		guard !q.isEmpty else { return attributed }
		var searchStart = text.startIndex
		while let range = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
			if let a = AttributedString.Index(range.lowerBound, within: attributed),
				let b = AttributedString.Index(range.upperBound, within: attributed) {
				attributed[a..<b].backgroundColor = Color.accentColor.opacity(0.28)
				attributed[a..<b].font = .system(size: 13, weight: .semibold)
			}
			searchStart = range.upperBound
		}
		return attributed
	}

	@ViewBuilder private var imageBody: some View {
		if let image = thumbnail {
			Image(nsImage: image)
				.resizable()
				.aspectRatio(contentMode: .fit)
				.clipShape(.rect(cornerRadius: Theme.smallRadius, style: .continuous))
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.padding(10)
				.background(Checkerboard())
		} else {
			placeholder(caption: clip.preview == .failed ? clip.text : nil)
				.transition(.opacity)
		}
	}

	@ViewBuilder private var linkBody: some View {
		VStack(alignment: .leading, spacing: 8) {
			if let image = thumbnail {
				Image(nsImage: image)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(width: 192, height: 100)
					.clipShape(.rect(cornerRadius: Theme.smallRadius, style: .continuous))
			} else {
				ZStack {
					RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous).fill(Theme.field)
					Image(systemName: clip.preview == .pending ? "link" : "globe")
						.font(.system(size: 30, weight: .regular))
						.foregroundStyle(Theme.ink.opacity(presentation.placeholderOpacity + 0.15))
				}
				.frame(width: 192, height: 100)
			}
			Text(presentation.fallback ?? clip.text)
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(Theme.ink)
				.lineLimit(2)
				.truncationMode(.tail)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.padding(12)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
	}

	@ViewBuilder private var fileBody: some View {
		VStack(spacing: 10) {
			ZStack {
				ForEach(Array(clip.fileNames.prefix(3).enumerated().reversed()), id: \.offset) { offset, name in
					fileIcon(name)
						.offset(x: CGFloat(offset) * 10, y: CGFloat(-offset) * 6)
						.opacity(offset == 0 ? 1 : 0.85)
				}
			}
			.frame(height: 96)
			HStack(spacing: 6) {
				Text(clip.fileNames.first ?? clip.text)
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(Theme.ink)
					.lineLimit(1)
					.truncationMode(presentation.fileNameTruncation)
				if clip.fileNames.count > 1 {
					Text("+\(clip.fileNames.count - 1)")
						.font(.system(size: 11, weight: .semibold).monospacedDigit())
						.foregroundStyle(Theme.ink)
						.padding(.horizontal, 6).padding(.vertical, 2)
						.background(Theme.field, in: .capsule)
				}
			}
			.padding(.horizontal, 12)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func fileIcon(_ name: String) -> some View {
		let ext = (name as NSString).pathExtension
		let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
		return Image(nsImage: icon).resizable().interpolation(.high).frame(width: 84, height: 84)
	}

	private var colorBody: some View {
		let hex = clip.colorHex ?? clip.text
		let rgb = Theme.rgb(UInt32(hex.dropFirst(), radix: 16) ?? 0)
		let ink = Theme.swatchInk(on: rgb)
		return ZStack {
			Rectangle().fill(Color(.sRGB, red: rgb.x, green: rgb.y, blue: rgb.z))
			Text(hex.uppercased())
				.font(.system(size: 15, weight: .semibold, design: .monospaced))
				.foregroundStyle(Color(.sRGB, red: ink.x, green: ink.y, blue: ink.z))
		}
	}

	private func placeholder(caption: String?) -> some View {
		VStack(spacing: 8) {
			Image(systemName: presentation.symbol)
				.font(.system(size: 30))
				.foregroundStyle(Theme.ink.opacity(presentation.placeholderOpacity))
			if let caption {
				Text(caption)
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(Theme.ink2(highContrast: highContrast))
					.lineLimit(2)
					.truncationMode(.middle)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 12)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

/// The 8 pt checkerboard behind transparent images: one 16×16 tile repeated by Core Animation.
/// (A SwiftUI Canvas here cost ~110 MB of GPU buffers inside the glass strip.)
private struct Checkerboard: View {
	static let tile: CGImage = {
		let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		ctx.setFillColor(CGColor(gray: 0.5, alpha: 0.09))
		ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
		ctx.fill(CGRect(x: 16, y: 16, width: 16, height: 16))
		return ctx.makeImage()!
	}()

	var body: some View {
		Image(decorative: Self.tile, scale: 2).resizable(resizingMode: .tile)
	}
}

import UniformTypeIdentifiers
