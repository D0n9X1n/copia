import AppKit
import ImageIO
import LinkPresentation
import QuickLookThumbnailing
import UniformTypeIdentifiers
import CopiaCore
import CopiaStore

/// Fetches a link's title and image. Tests supply a fake that counts calls.
public protocol LinkFetching: Sendable {
	func fetch(_ url: URL) async throws -> (title: String?, image: Data?)
}

/// LinkPresentation with a 10 s timeout; the image is reduced to a ≤480 px PNG.
public struct LiveLinkFetcher: LinkFetching {
	public init() {}
	@MainActor
	public func fetch(_ url: URL) async throws -> (title: String?, image: Data?) {
		let provider = LPMetadataProvider()
		provider.timeout = 10
		let metadata = try await provider.startFetchingMetadata(for: url)
		let title = metadata.title
		var image: Data?
		if let imageProvider = metadata.imageProvider {
			image = await withCheckedContinuation { continuation in
				_ = imageProvider.loadDataRepresentation(for: .image) { data, _ in
					continuation.resume(returning: data.flatMap { Previewer.thumbnailPNG(from: $0) })
				}
			}
		}
		return (title, image)
	}
}

/// Makes each clip's preview once, off the main thread, and saves it through the store.
/// Writes carry the clip's generation so a late result never lands on a deleted or recopied clip.
@MainActor
public final class Previewer {
	let store: ClipStore
	let links: LinkFetching
	public var onSaved: () -> Void = {}
	private var inFlight = Set<String>()

	public init(store: ClipStore, links: LinkFetching = LiveLinkFetcher()) {
		self.store = store
		self.links = links
	}

	public func generate(for clip: StoredClip) {
		let token = "\(clip.key)#\(clip.generation)"
		guard clip.previewState == .pending, !inFlight.contains(token) else { return }
		inFlight.insert(token)
		let store = self.store
		let links = self.links
		Task.detached(priority: .utility) {
			let (state, title, image) = await Self.make(for: clip, store: store, links: links)
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

	nonisolated static func make(for clip: StoredClip, store: ClipStore, links: LinkFetching) async
		-> (PreviewState, String?, Data?) {
		switch clip.kind {
		case .image:
			guard let items = try? await store.items(for: clip.key),
				let data = items.first?.data(for: PasteboardTypes.png) ?? items.first?.data(for: PasteboardTypes.tiff),
				let png = thumbnailPNG(from: data)
			else { return (.failed, nil, nil) }
			return (.ok, nil, png)
		case .link:
			guard let url = clip.url.flatMap(URL.init(string:)) else { return (.failed, nil, nil) }
			do {
				let result = try await links.fetch(url)
				return (result.image == nil ? .okNoImage : .ok, result.title, result.image)
			} catch {
				return (.failed, nil, nil)
			}
		case .file:
			guard let items = try? await store.items(for: clip.key),
				let path = items.first?.data(for: PasteboardTypes.fileURL).flatMap({ String(data: $0, encoding: .utf8) }),
				let url = URL(string: path)
			else { return (.failed, nil, nil) }
			let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 192, height: 192), scale: 2,
				representationTypes: .thumbnail)
			guard let thumb = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
				let png = pngData(thumb.cgImage)
			else { return (.failed, nil, nil) }
			return (.ok, nil, png)
		case .text, .richText, .color:
			return (.ok, nil, nil)
		}
	}

	/// Decodes at display size (≤480 px) and encodes PNG. shortcut: PNG for all thumbnails (alpha-safe); switch opaque ones to HEIC if disk use matters.
	nonisolated static func thumbnailPNG(from data: Data) -> Data? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil),
			let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
				kCGImageSourceCreateThumbnailFromImageAlways: true,
				kCGImageSourceThumbnailMaxPixelSize: 480,
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
