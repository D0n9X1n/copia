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
}
