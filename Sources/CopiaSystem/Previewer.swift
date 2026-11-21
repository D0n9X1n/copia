import AppKit
import ImageIO
import LinkPresentation
import QuickLookThumbnailing
import Synchronization
import UniformTypeIdentifiers
import CopiaCore
import CopiaStore

/// A link's title, preview image and site icon, each optional.
public struct LinkPreview: Sendable {
	public var title: String?
	public var image: Data?
	public var icon: Data?
	public init(title: String? = nil, image: Data? = nil, icon: Data? = nil) {
		self.title = title
		self.image = image
		self.icon = icon
	}
}

/// Fetches a link's preview. Tests supply a fake that counts calls.
public protocol LinkFetching: Sendable {
	func fetch(_ url: URL) async throws -> LinkPreview
}

/// LinkPresentation with a 10 s timeout; images are reduced to ≤384 px PNGs. The icon is loaded only without an image.
public struct LiveLinkFetcher: LinkFetching {
	public init() {}
	@MainActor
	public func fetch(_ url: URL) async throws -> LinkPreview {
		let provider = LPMetadataProvider()
		provider.timeout = 10
		let metadata = try await provider.startFetchingMetadata(for: url)
		let image = await Self.load(metadata.imageProvider)
		return LinkPreview(title: metadata.title, image: image, icon: image == nil ? await Self.load(metadata.iconProvider) : nil)
	}

	@MainActor
	static func load(_ provider: NSItemProvider?) async -> Data? {
		guard let provider else { return nil }
		return await withCheckedContinuation { continuation in
			_ = provider.loadDataRepresentation(for: .image) { data, _ in
				continuation.resume(returning: data.flatMap { Previewer.thumbnailPNG(from: $0) })
			}
		}
	}
}

/// Draws a file's thumbnail. Tests supply a fake.
public protocol FileThumbnailing: Sendable {
	func thumbnail(for url: URL) async throws -> Data
}

/// QuickLookThumbnailing at 96 pt, 2x.
public struct LiveFileThumbnails: FileThumbnailing {
	public init() {}
	public func thumbnail(for url: URL) async throws -> Data {
		let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 192, height: 192), scale: 2,
			representationTypes: .thumbnail)
		let thumb = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
		guard let png = Previewer.pngData(thumb.cgImage) else { throw CocoaError(.fileReadCorruptFile) }
		return png
	}
}

/// What preview work ran, for the one-decode and utility-QoS checks.
public final class PreviewStats: Sendable {
	private let state = Mutex<(decodes: Int, priorities: [TaskPriority])>((0, []))
	public var decodes: Int { state.withLock { $0.decodes } }
	public var priorities: [TaskPriority] { state.withLock { $0.priorities } }
	func decoded() { state.withLock { $0.decodes += 1 } }
	func ran(at priority: TaskPriority) { state.withLock { $0.priorities.append(priority) } }
}

/// Makes each clip's preview once, off the main thread, and saves it through the store.
/// Writes carry the clip's generation so a late result never lands on a deleted or recopied clip.
@MainActor
public final class Previewer {
	let store: ClipStore
	let links: LinkFetching
	let files: FileThumbnailing
	public let stats = PreviewStats()
	public var onSaved: () -> Void = {}
	private var inFlight = Set<String>()

	public init(store: ClipStore, links: LinkFetching = LiveLinkFetcher(), files: FileThumbnailing = LiveFileThumbnails()) {
		self.store = store
		self.links = links
		self.files = files
	}

	public func generate(for clip: StoredClip) {
		let token = "\(clip.key)#\(clip.generation)"
		guard clip.previewState == .pending, !inFlight.contains(token) else { return }
		inFlight.insert(token)
		let store = self.store
		let links = self.links
		let files = self.files
		let stats = self.stats
		Task.detached(priority: .utility) {
			stats.ran(at: Task.currentPriority)
			let (state, title, image) = await Self.make(for: clip, store: store, links: links, files: files, stats: stats)
			_ = try? await store.setPreview(key: clip.key, generation: clip.generation, state: state, title: title, image: image)
			await MainActor.run {
				self.inFlight.remove(token)
				self.onSaved()
			}
		}
	}

	/// Resumes anything left pending (after launch or an undo).
	public func resumePending() async {
		for clip in (try? await store.pending()) ?? [] { generate(for: clip) }
	}

	nonisolated static func make(for clip: StoredClip, store: ClipStore, links: LinkFetching, files: FileThumbnailing,
		stats: PreviewStats) async -> (PreviewState, String?, Data?) {
		switch clip.kind {
		case .image:
			guard let items = try? await store.items(for: clip.key),
				let data = items.first?.data(for: PasteboardTypes.png) ?? items.first?.data(for: PasteboardTypes.tiff)
			else { return (.failed, nil, nil) }
			stats.decoded()
			guard let png = thumbnailPNG(from: data) else { return (.failed, nil, nil) }
			return (.ok, nil, png)
		case .link:
			guard let url = clip.url.flatMap(URL.init(string:)) else { return (.failed, nil, nil) }
			do {
				let result = try await links.fetch(url)
				// Without a preview image the site icon is saved as the thumbnail; the state says which it is.
				return (result.image == nil ? .okNoImage : .ok, result.title, result.image ?? result.icon)
			} catch {
				return (.failed, nil, nil)
			}
		case .file:
			guard let items = try? await store.items(for: clip.key),
				let path = items.first?.data(for: PasteboardTypes.fileURL).flatMap({ String(data: $0, encoding: .utf8) }),
				let url = URL(string: path),
				let png = try? await files.thumbnail(for: url)
			else { return (.failed, nil, nil) }
			return (.ok, nil, png)
		case .text, .richText, .color:
			return (.ok, nil, nil)
		}
	}

	/// Decodes at display size (≤384 px: a 192 pt card at 2×) and encodes PNG, which keeps alpha and is lossless at this size.
	nonisolated static func thumbnailPNG(from data: Data) -> Data? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil),
			let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
				kCGImageSourceCreateThumbnailFromImageAlways: true,
				kCGImageSourceThumbnailMaxPixelSize: 384,
				kCGImageSourceCreateThumbnailWithTransform: true,
			] as CFDictionary)
		else { return nil }
		return pngData(image)
	}

	nonisolated static func pngData(_ image: CGImage) -> Data? {
		let out = NSMutableData()
		guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(dest, image, nil)
		return CGImageDestinationFinalize(dest) ? out as Data : nil
	}
}
