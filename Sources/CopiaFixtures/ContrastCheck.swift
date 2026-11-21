import Foundation
import CoreGraphics
import ImageIO

/// Measures WCAG contrast in captured renders: text on the glass against its backing, and the lens ring against its neighbors.
/// `copia-render` writes probe rectangles into `manifest.json`; `copia-render --check-contrast DIR` runs this over them.
public enum ContrastCheck {
	public static let textMinimum = 4.5
	public static let lensMinimum = 3.0

	/// A rectangle to measure, in points from the captured region's top-left corner.
	public struct Probe: Equatable, Sendable {
		public enum Kind: String, Sendable { case text, lens }
		public var kind: Kind
		public var name: String
		public var rect: CGRect

		public init(kind: Kind, name: String, rect: CGRect) {
			self.kind = kind
			self.name = name
			self.rect = rect
		}

		public var json: [String: Any] {
			["kind": kind.rawValue, "name": name, "x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height]
		}
	}

	public struct Result: Sendable {
		public var scene: String
		public var probe: String
		public var ratio: Double
		public var minimum: Double
		public var passes: Bool { ratio >= minimum }
	}

	/// Relative luminance of every pixel after conversion to sRGB, rows from the top.
	public struct Bitmap: Sendable {
		public let width: Int
		public let height: Int
		private let values: [Double]

		public init(_ image: CGImage) {
			width = image.width
			height = image.height
			var bytes = [UInt8](repeating: 0, count: width * height * 4)
			bytes.withUnsafeMutableBytes { buffer in
				let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
					bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
					bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
				ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
			}
			// A bitmap context's memory starts with the top row.
			values = (0..<width * height).map { i in
				luminance(SIMD3(Double(bytes[i * 4]), Double(bytes[i * 4 + 1]), Double(bytes[i * 4 + 2])) / 255)
			}
		}

		public init?(contentsOf url: URL) {
			guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
				let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
			self.init(image)
		}

		/// Luminance at a pixel, or nil outside the image.
		public subscript(x: Int, y: Int) -> Double? {
			guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
			return values[y * width + x]
		}

		func pixels(in rect: CGRect) -> [Double] {
			let r = rect.integral
			var out: [Double] = []
			for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { if let v = self[x, y] { out.append(v) } } }
			return out
		}
	}

	static func percentile(_ values: [Double], _ p: Double) -> Double {
		guard !values.isEmpty else { return 0 }
		let sorted = values.sorted()
		return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))]
	}

	static func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

	public static func luminance(_ c: SIMD3<Double>) -> Double {
		func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
		return 0.2126 * linear(c.x) + 0.7152 * linear(c.y) + 0.0722 * linear(c.z)
	}

	public static func contrast(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
		let (la, lb) = (luminance(a), luminance(b))
		return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
	}

	/// Text in `box` (points) against its backing: the ink is the box's darkest (or lightest) 1% of pixels, the backing
	/// the 2–6 pt bands above and below it, taking the band pixels nearest the ink (the worst case on variable glass).
	public static func text(in bitmap: Bitmap, box: CGRect, scale: CGFloat) -> Double {
		let px = CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale)
		let inside = bitmap.pixels(in: px)
		let (gap, band) = (2 * scale, 4 * scale)
		let backing = bitmap.pixels(in: CGRect(x: px.minX, y: px.minY - gap - band, width: px.width, height: band))
			+ bitmap.pixels(in: CGRect(x: px.minX, y: px.maxY + gap, width: px.width, height: band))
		guard !inside.isEmpty, !backing.isEmpty else { return 0 }
		let (darkInk, lightInk) = (percentile(inside, 0.01), percentile(inside, 0.99))
		let (darkest, lightest) = (percentile(backing, 0.05), percentile(backing, 0.95))
		// Dark text must stand off the darkest backing, light text off the lightest; the true polarity scores higher.
		let dark = darkInk < darkest ? ratio(darkInk, darkest) : 1
		let light = lightInk > lightest ? ratio(lightInk, lightest) : 1
		return max(dark, light)
	}

	/// The lens ring whose outer edge is `ring` (points): its 3 pt stroke against the pixels just outside it and the
	/// 2 pt gap inside it, sampled along the middle of all four sides. Returns a low (5th) percentile, so one stray
	/// pixel cannot pass or fail it.
	public static func lens(in bitmap: Bitmap, ring: CGRect, scale: CGFloat) -> Double {
		let (outside, stroke, gap) = (-1.0, 1.5, 4.0)  // points from the outer edge
		var ratios: [Double] = []
		func sample(_ at: (Double) -> (x: Double, y: Double)) {
			let points = [outside, stroke, gap].map { at($0) }
			let values = points.compactMap { bitmap[Int(($0.x * scale).rounded(.down)), Int(($0.y * scale).rounded(.down))] }
			guard values.count == 3 else { return }
			ratios.append(min(ratio(values[1], values[0]), ratio(values[1], values[2])))
		}
		for x in stride(from: ring.minX + ring.width * 0.25, through: ring.maxX - ring.width * 0.25, by: 1 / scale) {
			sample { (x, ring.minY + $0) }
			sample { (x, ring.maxY - $0) }
		}
		for y in stride(from: ring.minY + ring.height * 0.25, through: ring.maxY - ring.height * 0.25, by: 1 / scale) {
			sample { (ring.minX + $0, y) }
			sample { (ring.maxX - $0, y) }
		}
		return percentile(ratios, 0.05)
	}

	/// Measures every probe in `directory/manifest.json`. Each row needs `file`, `regionWidth` (points) and `probes`.
	public static func check(directory: URL) throws -> [Result] {
		let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
		let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
		var results: [Result] = []
		for row in rows {
			guard let probes = row["probes"] as? [[String: Any]], let file = row["file"] as? String,
				let regionWidth = (row["regionWidth"] as? NSNumber)?.doubleValue, regionWidth > 0 else { continue }
			let scene = (row["scene"] as? String) ?? file
			guard let bitmap = Bitmap(contentsOf: directory.appendingPathComponent(file)) else {
				throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file])
			}
			let scale = CGFloat(Double(bitmap.width) / regionWidth)
			for probe in probes {
				guard let kind = (probe["kind"] as? String).flatMap(Probe.Kind.init(rawValue:)),
					let name = probe["name"] as? String else { continue }
				func number(_ key: String) -> CGFloat { CGFloat((probe[key] as? NSNumber)?.doubleValue ?? 0) }
				let rect = CGRect(x: number("x"), y: number("y"), width: number("w"), height: number("h"))
				switch kind {
				case .text:
					results.append(Result(scene: scene, probe: name, ratio: text(in: bitmap, box: rect, scale: scale), minimum: textMinimum))
				case .lens:
					results.append(Result(scene: scene, probe: name, ratio: lens(in: bitmap, ring: rect, scale: scale), minimum: lensMinimum))
				}
			}
		}
		return results
	}

	/// 0 only when something was measured and everything passed.
	public static func exitCode(_ results: [Result]) -> Int32 {
		!results.isEmpty && results.allSatisfy(\.passes) ? 0 : 1
	}
}
