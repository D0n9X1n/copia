import AppKit
import ImageIO

/// Display-sized thumbnails, decoded off the main thread and cached up to 24 MB. Emptied whenever the strip hides.
@MainActor
public final class ThumbnailCache {
	public static let shared = ThumbnailCache()
	/// Cards draw images at most 192 pt wide, so 384 px covers 2× displays.
	public nonisolated static let maxPixelSize = 384
	public nonisolated static let costLimit = 24 * 1024 * 1024

	private let cache = NSCache<NSURL, NSImage>()
	private var keys = Set<URL>()
	private let decoder: @Sendable (URL) async -> CGImage?
	/// Bumped by `removeAll()`; a decode started before the purge is dropped when it lands.
	private var generation = 0
	public private(set) var decodeCount = 0

	/// `decode` runs off the main thread; tests inject one they can hold.
	public init(decode: (@Sendable (URL) async -> CGImage?)? = nil) {
		decoder = decode ?? { Self.decode($0) }
		cache.totalCostLimit = Self.costLimit
	}

	public var entryCount: Int { keys.filter { cache.object(forKey: $0 as NSURL) != nil }.count }

	/// A cached image, without decoding.
	public func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

	/// Returns the cached image or decodes it now. Used where a synchronous result is needed.
	public func image(at url: URL) -> NSImage? {
		if let hit = cached(url) { return hit }
		guard let cg = Self.decode(url) else { return nil }
		return store(cg, for: url)
	}

	/// Decodes on a background thread so opening the strip never waits for images.
	public func load(_ url: URL) async -> NSImage? {
		if let hit = cached(url) { return hit }
		let (decoder, started) = (decoder, generation)
		let cg = await Task.detached(priority: .userInitiated) { await decoder(url) }.value
		guard let cg, started == generation else { return nil }
		return cached(url) ?? store(cg, for: url)
	}

	private func store(_ cg: CGImage, for url: URL) -> NSImage {
		decodeCount += 1
		let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
		cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
		keys.insert(url)
		return image
	}

	nonisolated static func decode(_ url: URL) -> CGImage? {
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
		return CGImageSourceCreateThumbnailAtIndex(source, 0, [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,
		] as CFDictionary)
	}

	public func removeAll() {
		generation += 1
		cache.removeAllObjects()
		keys.removeAll()
	}
}
