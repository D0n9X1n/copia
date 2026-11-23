import Foundation
import Testing
@testable import CopiaApp
@testable import CopiaUI

@MainActor @Suite struct UpdateCheckTests {
	private actor RequestLog {
		var requests: [URLRequest] = []
		func record(_ request: URLRequest) -> Int { requests.append(request); return requests.count }
	}

	private func release(_ tag: String, status: Int = 200, draft: Bool = false, prerelease: Bool = false) throws -> String {
		let data = try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease])
		let response = HTTPURLResponse(url: URL(string: "https://api.github.com/repos/D0n9X1n/copia/releases/latest")!, statusCode: status, httpVersion: nil, headerFields: nil)!
		return try ReleaseLookup.version(data: data, response: response)
	}

	@Test func officialReleaseRequiresSuccessfulStableMetadata() throws {
		#expect(try release("v0.0.10") == "0.0.10")
		for status in [304, 404, 403, 429, 500] { #expect(throws: (any Error).self) { try release("v1.0.0", status: status) } }
		#expect(throws: (any Error).self) { try release("v1.0.0", draft: true) }
		#expect(throws: (any Error).self) { try release("v1.0.0", prerelease: true) }
		let other = HTTPURLResponse(url: URL(string: "https://example.invalid/release")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
		let valid = Data(#"{"tag_name":"v0.0.2","draft":false,"prerelease":false}"#.utf8)
		#expect(throws: (any Error).self) { try ReleaseLookup.version(data: valid, response: other) }
		let good = HTTPURLResponse(url: URL(string: "https://api.github.com/repos/D0n9X1n/copia/releases/latest")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
		#expect(throws: (any Error).self) { try ReleaseLookup.version(data: Data("{".utf8), response: good) }
		for tag in ["0.1.0", "v1.2", "v0.1.00", "v1.0.0-rc1", "v1.0.0+build", "v1.0.0/ignore", "v١.0.0"] {
			#expect(throws: (any Error).self) { try release(tag) }
		}
	}

	@Test func onlyManualLookupRequestsTheOfficialMetadataWithABoundedTimeout() async throws {
		let model = ShellModel(version: "0.0.2"); let log = RequestLog()
		model.latestVersion = {
			try await ReleaseLookup.latest { request in
				if await log.record(request) == 1 { throw URLError(.timedOut) }
				let data = Data(#"{"tag_name":"v0.0.10","draft":false,"prerelease":false,"html_url":"https://example.invalid/wrong"}"#.utf8)
				return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
			}
		}
		#expect(await log.requests.isEmpty)
		await model.checkForUpdates(); #expect(model.updateStatus == .failed)
		await model.checkForUpdates(); #expect(model.updateStatus == .available("0.0.10"))
		let requests = await log.requests
		#expect(requests.count == 2 && model.updateStatus.releaseURL?.absoluteString == "https://github.com/D0n9X1n/copia/releases/tag/v0.0.10")
		let request = try #require(requests.first)
		#expect(request.url?.absoluteString == "https://api.github.com/repos/D0n9X1n/copia/releases/latest" && request.httpMethod == "GET")
		#expect(request.httpBody == nil && request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
		#expect(request.timeoutInterval == 10 && request.value(forHTTPHeaderField: "User-Agent") == "Copia")
		#expect(request.httpShouldHandleCookies == false)
	}

	@Test func compareMajorMinorAndPatchNumerically() async {
		for (local, remote, newer) in [("0.0.2", "0.0.10", true), ("0.9.9", "0.10.0", true), ("1.0.0", "0.99.99", false), ("1.2.3", "1.2.3", false)] {
			let model = ShellModel(version: local); model.latestVersion = { remote }
			await model.checkForUpdates()
			#expect(model.updateStatus == (newer ? .available(remote) : .current))
		}
	}

	@Test func missingOrInvalidLocalVersionNeverMakesARequest() async {
		for version in [nil, "", "snapshot", "01.2.3"] as [String?] {
			let model = ShellModel(version: version); var calls = 0
			model.latestVersion = { calls += 1; return "1.0.0" }
			await model.checkForUpdates()
			#expect(calls == 0 && model.updateStatus == .idle)
		}
	}

	@Test func checkIsManualSingleFlightAndRetryable() async throws {
		let model = ShellModel(version: "0.0.2"); var calls = 0
		var pending: CheckedContinuation<String, any Error>?
		model.latestVersion = { calls += 1; return try await withCheckedThrowingContinuation { pending = $0 } }
		#expect(calls == 0 && model.updateStatus == .idle)
		let task = Task { await model.checkForUpdates() }
		try #require(await eventually { pending != nil })
		let started = try #require(pending)
		#expect(model.updateStatus == .checking)
		await model.checkForUpdates()
		#expect(calls == 1)
		started.resume(throwing: URLError(.notConnectedToInternet)); await task.value
		#expect(model.updateStatus == .failed)
		model.latestVersion = { calls += 1; return "0.1.0" }; await model.checkForUpdates()
		#expect(calls == 2 && model.updateStatus == .available("0.1.0"))
	}
}
