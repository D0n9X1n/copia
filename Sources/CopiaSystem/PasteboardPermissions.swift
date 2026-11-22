import AppKit

/// Read-side permission for capturing clipboard history.
public enum Permissions {
	public static var pasteboardAccess: NSPasteboard.AccessBehavior { NSPasteboard.general.accessBehavior }

	public static func openPasteboardSettings() {
		NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
	}
}
