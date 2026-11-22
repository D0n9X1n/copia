import Foundation
import CopiaUI
import CopiaSystem

@MainActor
final class ScratchServices: LoginService, LinkFetching, FileThumbnailing {
	var status: LoginStatus { .disabled }
	func register() throws { throw CocoaError(.featureUnsupported) }
	func unregister() throws { throw CocoaError(.featureUnsupported) }
	nonisolated func fetch(_ url: URL) async throws -> LinkPreview { throw CocoaError(.featureUnsupported) }
	nonisolated func thumbnail(for url: URL) async throws -> Data { throw CocoaError(.featureUnsupported) }
}
