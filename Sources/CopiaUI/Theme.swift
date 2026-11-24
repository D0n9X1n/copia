import AppKit
import SwiftUI

/// The single source of Copia's visual tokens (design brief, "System").
public enum Theme {
	enum Hex {
		static let inkLight: UInt32 = 0x1D1D1F
		static let inkDark: UInt32 = 0xF5F5F7
		static let ink2Light: UInt32 = 0x6E6E73
		static let ink2Dark: UInt32 = 0xA1A1A6
		static let cardLight: UInt32 = 0xFFFFFF
		static let cardDark: UInt32 = 0x2C2C2E
		static let brandLight: UInt32 = 0xFF6A3D
		static let brandDark: UInt32 = 0xFF7A50
		static let solidBackdropLight: UInt32 = 0xF2F2F7
		static let solidBackdropDark: UInt32 = 0x1C1C1E
		/// Metadata ink for text directly on the glass, whose backing varies with the wallpaper (ink2 is for solid cards).
		static let glassInk2Light: UInt32 = 0x48484D
		static let glassInk2Dark: UInt32 = 0xE0E0E5
	}

	/// Dark-mode black scrim over the glass: bounds how light the backing gets over a bright wallpaper.
	static let glassScrimDark = 0.22

	/// White in light mode and black in dark, unless the ring would fall below 3:1 against the halo or against the gap
	/// inside it (the halo tinted by the 12% fill); then the other extreme.
	static func lensHalo(accent: SIMD3<Double>, dark: Bool) -> SIMD3<Double> {
		func keepsRing(_ halo: SIMD3<Double>) -> Bool {
			contrast(accent, halo) >= 3 && contrast(accent, lensGap(accent: accent, halo: halo)) >= 3
		}
		let preferred = SIMD3<Double>(repeating: dark ? 0 : 1)
		if keepsRing(preferred) { return preferred }
		let other = SIMD3<Double>(repeating: dark ? 1 : 0)
		return keepsRing(other) ? other : extremeInk(on: accent)
	}

	/// The lens's 12% accent fill (brief).
	public static let lensFillOpacity = 0.12

	/// The gap inside the ring: the halo tinted by the accent fill.
	static func lensGap(accent: SIMD3<Double>, halo: SIMD3<Double>) -> SIMD3<Double> {
		composite(accent, over: halo, alpha: lensFillOpacity)
	}

	// MARK: Dimensions

	public static let panelInset: CGFloat = 8
	public static let panelHeight: CGFloat = 316
	public static let topBarHeight: CGFloat = 52
	public static let rowHeight: CGFloat = 248
	public static let bottomPadding: CGFloat = 16
	public static let cardSize = CGSize(width: 216, height: 232)
	public static let headerHeight: CGFloat = 40
	public static let bodyHeight: CGFloat = 164
	public static let footerHeight: CGFloat = 28
	public static let cardGap: CGFloat = 16
	public static let rowPadding: CGFloat = 24
	public static let scrollMargin: CGFloat = 24
	/// The band below the cards that holds the history scroll bar; it replaces the strip's bottom padding.
	public static let scrollBand: CGFloat = 16
	/// How far one notch of a plain mouse wheel moves the row: a quarter of a card.
	public static let wheelStep: CGFloat = (cardSize.width + cardGap) / 4
	public static let panelRadius: CGFloat = 28
	public static let cardRadius: CGFloat = 16
	public static let smallRadius: CGFloat = 8
	public static let lensRadius: CGFloat = 21
	public static let lensOutset: CGFloat = 5
	/// The lens halo's width outside the accent ring (it fits the row's 8 pt above and below a card).
	public static let lensHaloWidth: CGFloat = 2
	public static let headerTintAlpha = (light: 0.14, dark: 0.22)

	// MARK: Colors

	static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
		Color(nsColor: NSColor(name: nil) { appearance in
			let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
			return nsColor(isDark ? dark : light, alpha: alpha)
		})
	}

	static func nsColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
		let c = rgb(hex)
		return NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: alpha)
	}

	public static let ink = dynamic(Hex.inkLight, Hex.inkDark)
	public static let card = dynamic(Hex.cardLight, Hex.cardDark)
	public static let brand = dynamic(Hex.brandLight, Hex.brandDark)
	public static let solidBackdrop = dynamic(Hex.solidBackdropLight, Hex.solidBackdropDark)
	public static let field = Color(nsColor: NSColor(name: nil) { appearance in
		appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
			? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)
	})

	/// Metadata ink. Increase Contrast promotes it to `ink`.
	public static func ink2(highContrast: Bool) -> Color {
		highContrast ? ink : dynamic(Hex.ink2Light, Hex.ink2Dark)
	}

	/// Metadata ink for text directly on the glass (≥ 4.5:1 over the measured backing). Increase Contrast promotes it to `ink`.
	public static func glassInk2(highContrast: Bool) -> Color {
		highContrast ? ink : dynamic(Hex.glassInk2Light, Hex.glassInk2Dark)
	}

	static let glassInk2NS = NSColor(name: nil) { appearance in
		nsColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? Hex.glassInk2Dark : Hex.glassInk2Light)
	}

	/// Clear in light mode; a black scrim in dark mode, over the glass and under everything on it.
	public static let glassScrim = Color(nsColor: NSColor(name: nil) { appearance in
		appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.black.withAlphaComponent(glassScrimDark) : .clear
	})

	/// The lens's halo: fills the gap inside the accent ring and edges it outside, so the ring reaches 3:1 on any glass.
	public static let lensHalo = Color(nsColor: NSColor(name: nil) { appearance in
		let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
		var accent = SIMD3<Double>(0, 0.48, 1)
		appearance.performAsCurrentDrawingAppearance {
			if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
				accent = SIMD3(c.redComponent, c.greenComponent, c.blueComponent)
			}
		}
		let halo = lensHalo(accent: accent, dark: dark)
		return NSColor(srgbRed: halo.x, green: halo.y, blue: halo.z, alpha: 1)
	})

	/// Card stroke: 8% black / 10% white, 16% on hover, 25% with Increase Contrast.
	public static func stroke(hovered: Bool, highContrast: Bool) -> Color {
		let boost: CGFloat? = highContrast ? 0.25 : (hovered ? 0.16 : nil)
		return Color(nsColor: NSColor(name: nil) { appearance in
			let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
			return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(boost ?? (isDark ? 0.10 : 0.08))
		})
	}

	// MARK: Contrast math (WCAG 2.x)

	static func rgb(_ hex: UInt32) -> SIMD3<Double> {
		SIMD3(Double(hex >> 16 & 0xFF), Double(hex >> 8 & 0xFF), Double(hex & 0xFF)) / 255
	}

	static func luminance(_ c: SIMD3<Double>) -> Double {
		func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
		return 0.2126 * linear(c.x) + 0.7152 * linear(c.y) + 0.0722 * linear(c.z)
	}

	static func contrast(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
		let (la, lb) = (luminance(a), luminance(b))
		return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
	}

	static func composite(_ top: SIMD3<Double>, over bottom: SIMD3<Double>, alpha: Double) -> SIMD3<Double> {
		top * alpha + bottom * (1 - alpha)
	}

	/// Pure black or pure white, whichever contrasts more with `background`; always ≥ 4.58:1.
	static func extremeInk(on background: SIMD3<Double>) -> SIMD3<Double> {
		let black = SIMD3<Double>(0, 0, 0), white = SIMD3<Double>(1, 1, 1)
		return contrast(black, background) >= contrast(white, background) ? black : white
	}

	/// The hex label's ink on a color swatch.
	static func swatchInk(on swatch: SIMD3<Double>) -> SIMD3<Double> { extremeInk(on: swatch) }

	/// The lowest contrast of header ink over any allowed tint band, composited over the card.
	static func minimumHeaderContrast(dark: Bool) -> Double {
		let card = rgb(dark ? Hex.cardDark : Hex.cardLight)
		let ink = rgb(dark ? Hex.inkDark : Hex.inkLight)
		let alpha = dark ? headerTintAlpha.dark : headerTintAlpha.light
		var worst = Double.infinity
		for hue in stride(from: 0.0, to: 1.0, by: 1.0 / 72) {
			for s in [0.35, 0.7] {
				for b in [0.55, 0.85] {
					let band = composite(Tint(hue: hue, saturation: s, brightness: b).rgb, over: card, alpha: alpha)
					worst = min(worst, contrast(ink, band))
				}
			}
		}
		return worst
	}

	// MARK: Source tint

	/// A source app's color, as hue/saturation/brightness.
	public struct Tint: Equatable, Sendable {
		public var hue: Double
		public var saturation: Double
		public var brightness: Double

		var rgb: SIMD3<Double> {
			let c = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
				.usingColorSpace(.sRGB) ?? .gray
			return SIMD3(c.redComponent, c.greenComponent, c.blueComponent)
		}

		/// The header band fill, already at the brief's 14% (light) / 22% (dark) strength.
		public var band: Color {
			let c = rgb
			return Color(nsColor: NSColor(name: nil) { appearance in
				let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
				return NSColor(srgbRed: c.x, green: c.y, blue: c.z,
					alpha: isDark ? Theme.headerTintAlpha.dark : Theme.headerTintAlpha.light)
			})
		}
	}

	/// Neutral gray for clips whose source app is unknown.
	public static let neutralTint = Tint(hue: 0, saturation: 0, brightness: 0.62)

	static func clampTint(hue: Double, saturation: Double, brightness: Double) -> Tint {
		Tint(hue: hue, saturation: min(max(saturation, 0.35), 0.7), brightness: min(max(brightness, 0.55), 0.85))
	}

	/// Averages an icon's opaque pixels, weighted by alpha, then clamps the result.
	static func tint(averaging image: NSImage) -> Tint {
		let side = 16
		guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
			bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
			colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB)
		else { return neutralTint }
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
		image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
		NSGraphicsContext.restoreGraphicsState()

		var sum = SIMD3<Double>(repeating: 0)
		var weight = 0.0
		for x in 0..<side {
			for y in 0..<side {
				guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 else { continue }
				sum += SIMD3(c.redComponent, c.greenComponent, c.blueComponent) * c.alphaComponent
				weight += c.alphaComponent
			}
		}
		guard weight > 0 else { return neutralTint }
		let avg = sum / weight
		let color = NSColor(srgbRed: avg.x, green: avg.y, blue: avg.z, alpha: 1)
		return clampTint(hue: color.hueComponent, saturation: color.saturationComponent, brightness: color.brightnessComponent)
	}

	/// The header tint for an app icon. A missing icon (unknown source) gets the neutral tint.
	public static func sourceTint(for icon: NSImage?) -> Tint {
		icon.map(tint(averaging:)) ?? neutralTint
	}
}

/// Caches each source app's icon and tint by bundle ID.
@MainActor
public final class SourceAppearance {
	public static let shared = SourceAppearance(usesWorkspace: true)
	public static let fixtures = SourceAppearance(usesWorkspace: false)
	private let usesWorkspace: Bool
	private init(usesWorkspace: Bool) { self.usesWorkspace = usesWorkspace }
	private var cache: [String: (icon: NSImage, tint: Theme.Tint)] = [:]

	public func icon(for bundleID: String?) -> NSImage? { entry(for: bundleID)?.icon }
	public func tint(for bundleID: String?) -> Theme.Tint { entry(for: bundleID)?.tint ?? Theme.neutralTint }

	private func entry(for bundleID: String?) -> (icon: NSImage, tint: Theme.Tint)? {
		guard usesWorkspace, let bundleID else { return nil }
		if let hit = cache[bundleID] { return hit }
		guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
			let generic = (NSWorkspace.shared.icon(for: .application), Theme.neutralTint)
			cache[bundleID] = generic
			return generic
		}
		let icon = NSWorkspace.shared.icon(forFile: url.path)
		let entry = (icon, Theme.sourceTint(for: icon))
		cache[bundleID] = entry
		return entry
	}
}
