import Foundation
import CopiaCore

enum ReleaseLookup {
	private static let endpoint = URL(string: "https://api.github.com/repos/D0n9X1n/copia/releases/latest")!

	private struct Metadata: Decodable {
		let tag_name: String
		let draft: Bool
		let prerelease: Bool
	}

	private final class RejectRedirect: NSObject, URLSessionTaskDelegate {
		func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
			newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
	}

	static func latest() async throws -> String {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieStorage = nil
		configuration.urlCredentialStorage = nil
		configuration.urlCache = nil
		configuration.timeoutIntervalForResource = 10
		let session = URLSession(configuration: configuration, delegate: RejectRedirect(), delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }
		return try await latest { try await session.data(for: $0) }
	}

	static func latest(using load: @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws -> String {
		var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
		request.httpShouldHandleCookies = false
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("Copia", forHTTPHeaderField: "User-Agent")
		let (data, response) = try await load(request)
		return try version(data: data, response: response)
	}

	static func version(data: Data, response: URLResponse) throws -> String {
		guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == endpoint else { throw URLError(.badServerResponse) }
		let release = try JSONDecoder().decode(Metadata.self, from: data)
		guard !release.draft, !release.prerelease, release.tag_name.first == "v",
			let version = ReleaseVersion(String(release.tag_name.dropFirst())) else { throw URLError(.cannotParseResponse) }
		return version.string
	}
}
