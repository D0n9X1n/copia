import AppKit

/// One accessibility element of an in-process view, read through KVC: the Swift overlay leaves the
/// NSAccessibility protocol's optional members ambiguous. Used by tests and the render harness.
@MainActor
public struct AccessibilityNode {
	public let object: NSObject

	public init(_ object: NSObject) { self.object = object }

	/// SwiftUI builds its accessibility tree only for an assistive client; this makes it build one in-process.
	public static func enableInProcess() {
		_ = NSApplication.shared
		NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
	}

	private func read(_ key: String) -> Any? {
		object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
	}

	public var role: String? { read("accessibilityRole") as? String }
	public var label: String { (read("accessibilityLabel") as? String) ?? "" }
	public var value: String { (read("accessibilityValue") as? String) ?? "" }
	public var isSelected: Bool { (read("isAccessibilitySelected") as? Bool) ?? false }
	/// Screen coordinates, bottom-left origin.
	public var frame: CGRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
	public var actions: [NSAccessibilityCustomAction] {
		(read("accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []
	}
	public var children: [AccessibilityNode] {
		((read("accessibilityChildren") as? [Any]) ?? []).compactMap { ($0 as? NSObject).map(AccessibilityNode.init) }
	}
	/// This element and every descendant, depth first.
	public var all: [AccessibilityNode] { [self] + children.flatMap(\.all) }
}
