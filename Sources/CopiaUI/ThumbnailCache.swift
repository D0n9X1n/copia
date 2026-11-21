import AppKit
import ImageIO

/// Display-sized thumbnails, decoded once and capped at 64 MB. Emptied whenever the strip hides.
@MainActor
public final class ThumbnailCache {
	public static let shared = ThumbnailCache()
	public static let maxPixelSize = 480
	public static let costLimit = 64 * 1024 * 1024

	private let cache = NSCache<NSURL, NSImage>()
	private var keys = Set<URL>()
	public private(set) var decodeCount = 0

	public init() {
		cache.totalCostLimit = Self.costLimit
	}

	public var entryCount: Int { keys.filter { cache.object(forKey: $0 as NSURL) != nil }.count }

	public func image(at url: URL) -> NSImage? {
		if let hit = cache.object(forKey: url as NSURL) { return hit }
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
			let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
				kCGImageSourceCreateThumbnailFromImageAlways: true,
				kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
				kCGImageSourceCreateThumbnailWithTransform: true,
			] as CFDictionary)
		else { return nil }
		decodeCount += 1
		let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
		cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
		keys.insert(url)
		return image
	}

	public func removeAll() {
		cache.removeAllObjects()
		keys.removeAll()
	}
}
