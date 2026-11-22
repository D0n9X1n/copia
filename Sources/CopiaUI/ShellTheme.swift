import AppKit
import SwiftUI

/// Settings and onboarding colors that keep text at 4.5:1 or better on the window in both modes.
public enum ShellTheme {
	enum Hex {
		static let secondaryLight: UInt32 = 0x636366
		static let secondaryDark: UInt32 = 0xAEAEB2
		static let errorLight: UInt32 = 0xB3261E
		static let errorDark: UInt32 = 0xFF8A80
		/// Brand orange deepened so white labels keep 4.5:1 under Liquid Glass. The system accent is the user's
		/// choice and can't promise that, so prominent buttons use this fixed pair in both modes.
		static let accent: UInt32 = 0xB0360F
		static let onAccent: UInt32 = 0xFFFFFF
	}

	/// Body copy that `.secondary` would draw below 4.5:1.
	public static let secondary = Theme.dynamic(Hex.secondaryLight, Hex.secondaryDark)
	/// Error copy on grouped Settings rows; system red is too faint for small text.
	public static let error = Theme.dynamic(Hex.errorLight, Hex.errorDark)
	public static let accent = Color(nsColor: Theme.nsColor(Hex.accent))
	public static let onAccent = Color(nsColor: Theme.nsColor(Hex.onAccent))
}

extension View {
	/// The main action: prominent glass on the fixed accent, with a white label.
	func shellProminentButton() -> some View {
		buttonStyle(.glassProminent).tint(ShellTheme.accent).foregroundStyle(ShellTheme.onAccent)
	}
}
