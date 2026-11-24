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

	/// What a card without its preview shows: the symbol plus a link's title, a filename or the text.
	var fallback: String? {
		guard clip.preview == .failed else { return nil }
		return clip.kind == .link ? title : (clip.fileNames.first ?? clip.text)
	}

	var footer: String { clip.meta }

	/// What the body draws. Rich text stays plain text (with its RTF meta) for this release.
	enum BodyKind: Equatable { case code, prose, image, link, file, color }

	var bodyKind: BodyKind {
		switch clip.kind {
		case .text, .richText: clip.isCode ? .code : .prose
		case .image: .image
		case .link: .link
		case .file: .file
		case .color: .color
		}
	}

	/// The saved image the card decodes: a thumbnail, or a link's site icon.
	var previewURL: URL? {
		switch clip.preview {
		case let .ready(url), let .icon(url): url
		case .pending, .failed: nil
		}
	}

	// MARK: Links

	enum LinkArt: Equatable { case hero(URL), favicon(URL), glyph }

	var linkArt: LinkArt {
		switch clip.preview {
		case let .ready(url): .hero(url)
		case let .icon(url): .favicon(url)
		case .pending, .failed: .glyph
		}
	}

	var faviconSide: CGFloat { 32 }
	/// A link's title (its URL when the page had none), shown in every preview state.
	var title: String { clip.text }
	var titleLines: Int { 2 }

	// MARK: Files

	var fileThumbnailSide: CGFloat { 96 }
	/// The first file's saved QuickLook thumbnail.
	var fileThumbnail: URL? {
		guard clip.kind == .file, case let .ready(url) = clip.preview else { return nil }
		return url
	}
	/// Layers in the offset stack: one per file, at most three.
	var fileStack: Int { min(max(clip.fileNames.count, 1), 3) }
	var fileCount: String? { clip.fileNames.count > 1 ? "+\(clip.fileNames.count - 1)" : nil }

	// MARK: Direction

	/// Natural alignment: right-to-left text aligns to the right.
	var textDirection: LayoutDirection { Self.direction(of: clip.text) }

	/// The direction of the first strong (letter) character, as natural alignment decides it.
	static func direction(of text: String) -> LayoutDirection {
		for scalar in text.unicodeScalars.prefix(500) where scalar.properties.isAlphabetic {
			return isRightToLeft(scalar) ? .rightToLeft : .leftToRight
		}
		return .leftToRight
	}

	private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar.value {
		// Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, Arabic Extended, presentation forms.
		case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: true
		default: false
		}
	}
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
	let age: String
	let highlight: String
	let thumbnails: ThumbnailCache
	/// Runs the preview fade-in, so it comes from the Motion table and tests see it.
	let animator: Animator
	/// Shows the footer pin button; a pinned card always shows its filled pin.
	var showsPin = false
	/// Reserves the footer pin slot, so the strip's click gesture can toggle the pin there. False keeps the static
	/// footer (design renders).
	var pinControl = false

	/// The pin button's hit area in card coordinates: the footer's trailing 24×24 slot. The strip is always laid out
	/// left to right, so this is the right-hand end. The card's click gesture ignores presses that start on a visible pin.
	static let pinSlot = CGRect(x: Theme.cardSize.width - 12 - 24, y: Theme.cardSize.height - Theme.footerHeight + 2, width: 24, height: 24)

	@Environment(\.colorSchemeContrast) private var contrast
	@Environment(\.colorScheme) private var scheme
	@Environment(\.accessibilityReduceMotion) private var systemReduceMotion
	@Environment(\.copiaOverrides) private var overrides
	private var highContrast: Bool { overrides.highContrast ?? (contrast == .increased) }
	private var reduceMotion: Bool { overrides.reduceMotion ?? systemReduceMotion }
	private var p: CardPresentation { CardPresentation(clip: clip) }

	var body: some View {
		let _ = Diagnostics.body()
		VStack(spacing: 0) {
			header
			CardBody(clip: clip, presentation: p, highContrast: highContrast, highlight: highlight, thumbnails: thumbnails,
				animator: animator)
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
		.background {
			RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
				.fill(Theme.card)
				.shadow(color: .black.opacity(selected ? 0.18 : (scheme == .dark ? 0.30 : 0.10)),
					radius: selected ? 9 : 4, y: selected ? 6 : 2)
		}
		.scaleEffect(StripMotion.removingScale(removing: removing, reduced: reduceMotion))
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
			Text(Self.grown(p.typeLabel, by: overrides.labelGrowth))
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(Theme.ink)
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer(minLength: 4)
			Text(Self.grown(age, by: overrides.labelGrowth))
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
			if pinControl {
				// The slot is reserved even when empty, so hovering never reflows the footer text.
				PinGlyph(pinned: clip.isPinned, shown: clip.isPinned || showsPin, highContrast: highContrast)
			} else if clip.isPinned {
				Image(systemName: "pin.fill").foregroundStyle(Theme.ink)
			}
		}
		.padding(.horizontal, 12)
		.frame(height: Theme.footerHeight)
	}

	/// `label` lengthened to `factor` times its length by repeating its letters after it, or unchanged when nil.
	nonisolated static func grown(_ label: String, by factor: Double?) -> String {
		guard let factor, factor > 1, !label.isEmpty else { return label }
		let extra = Int((Double(label.count) * (factor - 1)).rounded(.up))
		return label + String(String(repeating: label.lowercased(), count: extra / label.count + 1).prefix(extra))
	}

	nonisolated static func relative(_ date: Date, now: Date) -> String {
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

/// The footer's pin: filled when pinned, an outline on the hovered or primary card, otherwise an empty slot.
/// A plain image, not a Button: a Button mounted on the primary card added ~5 ms to every ⌘Y open.
/// StripView's card gesture turns a click that starts and ends on it into a pin toggle.
private struct PinGlyph: View {
	let pinned: Bool
	let shown: Bool
	let highContrast: Bool
	@State private var hovering = false

	var body: some View {
		Group {
			if shown {
				Image(systemName: pinned ? "pin.fill" : "pin")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(pinned || hovering ? Theme.ink : Theme.ink2(highContrast: highContrast))
					.frame(width: ClipCard.pinSlot.width, height: ClipCard.pinSlot.height)
					.background {
						if hovering { RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous).fill(Theme.field) }
					}
					.contentShape(.rect)
					.onHover { hovering = $0 }
					.help(pinned ? "Unpin" : "Pin")
			} else {
				Color.clear.allowsHitTesting(false)
			}
		}
		.frame(width: ClipCard.pinSlot.width, height: ClipCard.pinSlot.height)
	}
}

/// The 164 pt body, drawn per kind.
private struct CardBody: View {
	let clip: Clip
	let presentation: CardPresentation
	let highContrast: Bool
	let highlight: String
	let thumbnails: ThumbnailCache
	let animator: Animator
	/// Bumped when a background decode lands; the image itself lives only in the size-limited cache.
	@State private var decoded = 0

	private var previewURL: URL? { presentation.previewURL }

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
				// The loading fade comes from the Motion table, through the Animator.
				animator.run(.loading, { decoded += 1 }, {})
			}
	}

	@ViewBuilder private var content: some View {
		switch presentation.bodyKind {
		case .code: codeBody
		case .prose: proseBody
		case .image: imageBody
		case .link: linkBody
		case .file: fileBody
		case .color: colorBody
		}
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
			// Natural alignment: leading follows the text's own direction.
			.environment(\.layoutDirection, presentation.textDirection)
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
			placeholder(caption: presentation.fallback)
				.transition(.opacity)
		}
	}

	@ViewBuilder private var linkBody: some View {
		VStack(alignment: .leading, spacing: 8) {
			if case .hero = presentation.linkArt, let image = thumbnail {
				Image(nsImage: image)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(width: 192, height: 100)
					.clipShape(.rect(cornerRadius: Theme.smallRadius, style: .continuous))
			} else {
				ZStack {
					RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous).fill(Theme.field)
					if case .favicon = presentation.linkArt, let icon = thumbnail {
						// A saved site icon: a 32 pt favicon, no preview image.
						Image(nsImage: icon)
							.resizable()
							.interpolation(.high)
							.aspectRatio(contentMode: .fit)
							.frame(width: presentation.faviconSide, height: presentation.faviconSide)
							.clipShape(.rect(cornerRadius: 6, style: .continuous))
					} else {
						// Loading: the type symbol at 30%. A failed preview keeps a stronger glyph beside its title.
						Image(systemName: presentation.symbol)
							.font(.system(size: 30, weight: .regular))
							.foregroundStyle(Theme.ink.opacity(presentation.placeholderOpacity
								+ (clip.preview == .failed ? 0.15 : 0)))
					}
				}
				.frame(width: 192, height: 100)
			}
			Text(presentation.title)
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(Theme.ink)
				.lineLimit(presentation.titleLines)
				.truncationMode(.tail)
				.frame(maxWidth: .infinity, alignment: .leading)
				.environment(\.layoutDirection, presentation.textDirection)
		}
		.padding(12)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
	}

	/// A file whose QuickLook thumbnail is not on screen yet: pending, or saved but not decoded.
	private var fileLoading: Bool {
		clip.preview == .pending || (presentation.fileThumbnail != nil && thumbnail == nil)
	}

	@ViewBuilder private var fileBody: some View {
		VStack(spacing: 10) {
			Group {
				if fileLoading {
					Image(systemName: presentation.symbol)
						.font(.system(size: 30))
						.foregroundStyle(Theme.ink.opacity(presentation.placeholderOpacity))
						.transition(.opacity)
				} else {
					ZStack {
						ForEach((0..<presentation.fileStack).reversed(), id: \.self) { offset in
							fileLayer(offset)
								.offset(x: CGFloat(offset) * 10, y: CGFloat(-offset) * 6)
								.opacity(offset == 0 ? 1 : 0.85)
						}
					}
				}
			}
			.frame(height: presentation.fileThumbnailSide)
			HStack(spacing: 6) {
				Text(clip.fileNames.first ?? clip.text)
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(Theme.ink)
					.lineLimit(1)
					.truncationMode(presentation.fileNameTruncation)
				if let count = presentation.fileCount {
					Text(count)
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

	/// One layer of the file stack: the saved QuickLook thumbnail in front when there is one, else the type icon.
	@ViewBuilder private func fileLayer(_ offset: Int) -> some View {
		let side = presentation.fileThumbnailSide
		if offset == 0, presentation.fileThumbnail != nil, let image = thumbnail {
			Image(nsImage: image)
				.resizable()
				.interpolation(.high)
				.aspectRatio(contentMode: .fit)
				.frame(maxWidth: side, maxHeight: side)
				.clipShape(.rect(cornerRadius: 4, style: .continuous))
				.shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
				.frame(width: side, height: side)
		} else {
			let names = clip.fileNames.isEmpty ? [clip.text] : clip.fileNames
			let ext = (names[min(offset, names.count - 1)] as NSString).pathExtension
			Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data))
				.resizable().interpolation(.high).frame(width: 84, height: 84)
				.frame(width: side, height: side)
		}
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

/// Every card at once on the strip's glass: the render harness's extremes sheet.
public struct CardSheet: View {
	let clips: [Clip]
	let thumbnails: ThumbnailCache
	let now: Date
	let columns: Int
	let sources: SourceAppearance
	@Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
	@Environment(\.copiaOverrides) private var overrides

	public init(clips: [Clip], thumbnails: ThumbnailCache, now: Date, columns: Int = 6, sources: SourceAppearance = .shared) {
		self.clips = clips
		self.thumbnails = thumbnails
		self.now = now
		self.columns = columns
		self.sources = sources
	}

	private var rows: [[Clip]] {
		stride(from: 0, to: clips.count, by: columns).map { Array(clips[$0..<min($0 + columns, clips.count)]) }
	}

	public var body: some View {
		let shape = RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
		Grid(alignment: .topLeading, horizontalSpacing: Theme.cardGap, verticalSpacing: Theme.cardGap) {
			ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
				GridRow {
					ForEach(row) { clip in
						ClipCard(clip: clip, tint: clip.sourceBundleID == nil ? Theme.neutralTint : sources.tint(for: clip.sourceBundleID),
							icon: sources.icon(for: clip.sourceBundleID), badge: nil, hovered: false, selected: false, removing: false,
							age: ClipCard.relative(clip.timestamp, now: now), highlight: "", thumbnails: thumbnails, animator: .immediate)
							.accessibilityElement(children: .ignore)
							.accessibilityLabel(CardAccessibility(clip: clip, now: now).label)
					}
				}
			}
		}
		.padding(Theme.rowPadding)
		.background {
			if overrides.reduceTransparency ?? systemReduceTransparency {
				shape.fill(Theme.solidBackdrop)
			} else {
				Color.clear.glassEffect(.regular, in: shape).clipShape(shape)
					.overlay { shape.fill(Theme.glassScrim) }
			}
		}
		.overlay { shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5) }
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
