import Testing
import AppKit
@testable import CopiaUI

@Suite struct ThemeTests {
	@Test func tokenTextContrastMeetsAA() {
		for dark in [false, true] {
			let card = Theme.rgb(dark ? Theme.Hex.cardDark : Theme.Hex.cardLight)
			#expect(Theme.contrast(Theme.rgb(dark ? Theme.Hex.inkDark : Theme.Hex.inkLight), card) >= 4.5)
			#expect(Theme.contrast(Theme.rgb(dark ? Theme.Hex.ink2Dark : Theme.Hex.ink2Light), card) >= 4.5)
		}
	}

	@Test func worstTintHeaderContrastMeetsAA() {
		for dark in [false, true] {
			#expect(Theme.minimumHeaderContrast(dark: dark) >= 4.5)
		}
	}

	@Test(arguments: stride(from: 0.0, through: 1.0, by: 0.05).map { $0 })
	func tintIsClampedForEveryHue(hue: Double) {
		for (s, b) in [(0.0, 0.0), (1.0, 1.0), (0.1, 0.95), (0.95, 0.1), (0.5, 0.5)] {
			let t = Theme.clampTint(hue: hue, saturation: s, brightness: b)
			#expect((0.35...0.7).contains(t.saturation))
			#expect((0.55...0.85).contains(t.brightness))
		}
	}

	@Test func iconTintIsClamped() {
		let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
			NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill(); rect.fill(); return true
		}
		let t = Theme.tint(averaging: image)
		#expect((0.35...0.7).contains(t.saturation))
		#expect((0.55...0.85).contains(t.brightness))
	}

	@Test func unknownSourceUsesNeutralTint() {
		#expect(Theme.sourceTint(for: nil) == Theme.neutralTint)
	}

	@Test(arguments: [(0xFFFFFF as UInt32, false), (0x000000, true), (0x808080, false)])
	func swatchInkIsBlackOrWhiteAndReachesAA(hex: UInt32, expectWhite: Bool) {
		let swatch = Theme.rgb(hex)
		let ink = Theme.swatchInk(on: swatch)
		#expect(ink == (expectWhite ? SIMD3(1, 1, 1) : SIMD3(0, 0, 0)))
		#expect(Theme.contrast(ink, swatch) >= 4.5)
	}

	@Test func swatchInkReachesAAOnEveryGray() {
		for v in 0...255 {
			let swatch = SIMD3(repeating: Double(v) / 255)
			#expect(Theme.contrast(Theme.swatchInk(on: swatch), swatch) >= 4.5)
		}
	}

	/// Linear luminance → the sRGB gray that has it.
	func gray(luminance: Double) -> SIMD3<Double> {
		let v = luminance <= 0.0031308 ? luminance * 12.92 : 1.055 * pow(luminance, 1 / 2.4) - 0.055
		return SIMD3(repeating: v)
	}

	/// The glass's backing, as `copia-render --check-contrast` measured it over the bright and dark wallpapers
	/// (light: 0.60-0.88 on the glass, ~0.53 under the search field; dark: 0.05-0.12, before the scrim), widened.
	@Test func secondaryInkOnTheGlassReachesAAOverTheMeasuredBacking() {
		let lightInk = Theme.rgb(Theme.Hex.glassInk2Light)
		for backing in stride(from: 0.50, through: 1.0, by: 0.01) {
			#expect(Theme.contrast(lightInk, gray(luminance: backing)) >= 4.5, "light on \(backing)")
		}
		let darkInk = Theme.rgb(Theme.Hex.glassInk2Dark)
		for backing in stride(from: 0.0, through: 0.14, by: 0.01) {
			// The dark-mode scrim darkens the glass, then the search field lightens it by 8% white.
			let glass = Theme.composite(SIMD3(repeating: 0), over: gray(luminance: backing), alpha: Theme.glassScrimDark)
			let field = Theme.composite(SIMD3(repeating: 1), over: glass, alpha: 0.08)
			#expect(Theme.contrast(darkInk, glass) >= 4.5, "dark on \(backing)")
			#expect(Theme.contrast(darkInk, field) >= 4.5, "dark field on \(backing)")
		}
	}

	@Test func glassInkKeepsItsHierarchyBelowPrimaryInk() {
		let card = (light: Theme.rgb(Theme.Hex.cardLight), dark: Theme.rgb(Theme.Hex.cardDark))
		#expect(Theme.contrast(Theme.rgb(Theme.Hex.glassInk2Light), card.light) < Theme.contrast(Theme.rgb(Theme.Hex.inkLight), card.light))
		#expect(Theme.contrast(Theme.rgb(Theme.Hex.glassInk2Dark), card.dark) < Theme.contrast(Theme.rgb(Theme.Hex.inkDark), card.dark))
	}

	@Test func lensHaloIsWhiteInLightAndBlackInDarkForTheDefaultAccent() {
		#expect(Theme.lensHalo(accent: Theme.rgb(0x007AFF), dark: false) == SIMD3(1, 1, 1))
		#expect(Theme.lensHalo(accent: Theme.rgb(0x0A84FF), dark: true) == SIMD3(0, 0, 0))
	}

	/// The halo sits on both sides of the accent ring, so the ring reaches 3:1 against its neighbors on any glass.
	@Test func lensHaloKeepsTheRingAt3To1ForEveryAccent() {
		// macOS accent colors (light, dark) plus a sweep of hues.
		var accents: [UInt32] = [0x007AFF, 0x0A84FF, 0xA550A7, 0xBF5AF2, 0xF74F9E, 0xFF375F, 0xFF5257, 0xFF453A,
			0xF7821B, 0xFF9F0A, 0xFFC600, 0xFFD60A, 0x62BA46, 0x32D74B, 0x8C8C8C, 0x98989D]
		for hue in stride(from: 0.0, to: 1.0, by: 1.0 / 36) {
			for (s, b) in [(1.0, 1.0), (0.6, 0.8), (0.8, 0.5)] {
				let c = NSColor(hue: hue, saturation: s, brightness: b, alpha: 1).usingColorSpace(.sRGB)!
				accents.append(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
			}
		}
		for hex in accents {
			for dark in [false, true] {
				let accent = Theme.rgb(hex)
				#expect(Theme.contrast(accent, Theme.lensHalo(accent: accent, dark: dark)) >= 3, "\(String(hex, radix: 16)) dark=\(dark)")
			}
		}
	}
}
