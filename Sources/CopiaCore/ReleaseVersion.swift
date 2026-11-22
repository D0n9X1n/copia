import Foundation

public struct ReleaseVersion: Comparable, Sendable {
	public let string: String
	private let parts: [Substring]

	public init?(_ string: String) {
		let parts = string.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 3, parts.allSatisfy({ part in
			!part.isEmpty && (part == "0" || part.first != "0") && part.utf8.allSatisfy { (48...57).contains($0) }
		}) else { return nil }
		self.string = string
		self.parts = parts
	}

	public static func < (lhs: Self, rhs: Self) -> Bool {
		for (a, b) in zip(lhs.parts, rhs.parts) where a != b {
			return a.utf8.count == b.utf8.count ? a < b : a.utf8.count < b.utf8.count
		}
		return false
	}
}
