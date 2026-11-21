import CoreGraphics

/// The app icon review sheet: each rendition at 1024, 128, 32 and 16 px, a light row over a dark row.
/// Pure composition from exported renditions, so it needs no window and no screen capture.
public enum IconReview {
	public static let sizes = [1024, 128, 32, 16]
	public static let pad = 40
	public static let lightBackground: [UInt8] = [245, 245, 245, 255]
	public static let darkBackground: [UInt8] = [31, 31, 31, 255]

	/// Where one icon sits, in pixels from the sheet's top-left.
	public struct Frame: Sendable, CustomStringConvertible {
		public let size: Int
		public let dark: Bool
		public let rect: CGRect
		public var description: String { "\(dark ? "dark" : "light") \(size) px at \(rect)" }
	}

	static var rowHeight: Int { sizes.max()! + 2 * pad }

	public static var size: CGSize {
		CGSize(width: pad + sizes.reduce(0) { $0 + $1 + pad }, height: 2 * rowHeight)
	}

	public static var frames: [Frame] {
		var frames: [Frame] = []
		for (row, dark) in [false, true].enumerated() {
			var x = pad
			for side in sizes {
				let y = row * rowHeight + (rowHeight - side) / 2
				frames.append(Frame(size: side, dark: dark, rect: CGRect(x: x, y: y, width: side, height: side)))
				x += side + pad
			}
		}
		return frames
	}

	/// The sheet, or nil if a bitmap context cannot be made.
	public static func sheet(light: CGImage, dark: CGImage) -> CGImage? {
		let width = Int(size.width), height = Int(size.height)
		guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		for (row, color) in [lightBackground, darkBackground].enumerated() {
			ctx.setFillColor(CGColor(srgbRed: CGFloat(color[0]) / 255, green: CGFloat(color[1]) / 255, blue: CGFloat(color[2]) / 255, alpha: 1))
			// Core Graphics counts rows from the bottom.
			ctx.fill(CGRect(x: 0, y: height - (row + 1) * rowHeight, width: width, height: rowHeight))
		}
		ctx.interpolationQuality = .high
		for frame in frames {
			let r = frame.rect
			ctx.draw(frame.dark ? dark : light, in: CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height))
		}
		return ctx.makeImage()
	}
}
