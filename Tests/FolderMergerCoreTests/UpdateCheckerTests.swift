import XCTest
import Foundation
@testable import FolderMergerCore

final class UpdateCheckerTests: XCTestCase {
    private struct Stub: UpdateTransport {
        var currentVersion = "1.0"
        var status = 200
        var headers: [String: String] = [:]
        var body: Data
        var error: URLError?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            XCTAssertEqual(request.url, UpdateChecker.endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "FolderMerger/\(currentVersion)")
            XCTAssertEqual(request.timeoutInterval, 15)
            if let error { throw error }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }
    private let page = "https://github.com/kimipooh/folder-merger-for-macos/releases/tag/v2.0"
    private func payload(tag: String = "v2.0", url: String? = nil, draft: Bool = false, prerelease: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": url ?? page, "draft": draft, "prerelease": prerelease])
    }
    private func check(_ data: Data, status: Int = 200, headers: [String: String] = [:]) async -> UpdateCheckResult {
        await UpdateChecker(transport: Stub(status: status, headers: headers, body: data)).check(currentVersion: "1.0")
    }
    func testNewVersion() async {
        let result = await check(payload())
        XCTAssertEqual(result, .available(version: "v2.0", url: URL(string: page)!))
    }
    func testEqualAndOlderVersions() async {
        for tag in ["v1.0.0", "V1.0", "0.9"] {
            let result = await check(payload(tag: tag))
            XCTAssertEqual(result, .upToDate)
        }
    }
    func testMultiDigitReleaseResponse() async {
        let checker = UpdateChecker(transport: Stub(currentVersion: "1.9.0", body: payload(tag: "v1.10.0")))
        let result = await checker.check(currentVersion: "1.9.0")
        XCTAssertEqual(result, .available(version: "v1.10.0", url: URL(string: page)!))
    }
    func testDecimalComparison() {
        XCTAssertGreaterThan(ReleaseVersion("1.10.0")!, ReleaseVersion("1.9.0")!)
        XCTAssertEqual(ReleaseVersion("01.0"), ReleaseVersion("1.0.0"))
        XCTAssertGreaterThan(ReleaseVersion("999999999999999999999999")!, ReleaseVersion("2")!)
        for value in ["", "v1", "-1", "1..0", "1.0-beta", "1. 0", "１.0", "1."] {
            XCTAssertNil(ReleaseVersion(value), value)
        }
    }
    func testHTTPClassification() async {
        for (status, headers, expected) in [
            (404, [:], UpdateCheckResult.noRelease),
            (403, ["X-RateLimit-Remaining": "0"], .rateLimited),
            (429, [:], .rateLimited), (403, [:], .rateLimited),
            (200, ["X-RateLimit-Remaining": "0"], .rateLimited),
            (500, [:], .invalidResponse), (302, [:], .invalidResponse)
        ] {
            let result = await check(payload(), status: status, headers: headers)
            XCTAssertEqual(result, expected)
        }
    }
    func testNetworkFailures() async {
        for code in [URLError.notConnectedToInternet, .timedOut] {
            let result = await UpdateChecker(transport: Stub(body: Data(), error: URLError(code))).check(currentVersion: "1.0")
            XCTAssertEqual(result, .networkError)
        }
    }
    func testInvalidResponses() async {
        for data in [Data("not JSON".utf8), Data("{}".utf8),
                     Data("{\"tag_name\":\"v2.0\"}".utf8),
                     Data("{\"html_url\":\"https://github.com\"}".utf8),
                     payload(tag: "vabc"), payload(tag: "1.0-beta"), payload(tag: ""),
                     payload(draft: true), payload(prerelease: true)] {
            let result = await check(data)
            XCTAssertEqual(result, .invalidResponse)
        }
        let result = await UpdateChecker(transport: Stub(body: payload())).check(currentVersion: "unknown")
        XCTAssertEqual(result, .invalidResponse)
    }
    func testStrictReleaseURL() async {
        for url in [
            page.replacingOccurrences(of: "https:", with: "http:"),
            page.replacingOccurrences(of: "github.com", with: "example.com"),
            page.replacingOccurrences(of: "github.com", with: "github.com.evil.example"),
            page.replacingOccurrences(of: "folder-merger-for-macos", with: "other"),
            page.replacingOccurrences(of: "github.com", with: "GITHUB.COM"),
            page.replacingOccurrences(of: "https", with: "HTTPS"),
            page.replacingOccurrences(of: "github.com", with: "user@github.com"),
            page.replacingOccurrences(of: "github.com", with: "github.com:443"),
            page.replacingOccurrences(of: "kimipooh", with: "Kimipooh"),
            "https://github.com/kimipooh/folder-merger-for-macos/releases/../../../other",
            "https://github.com/kimipooh/folder-merger-for-macos/releases/%2e%2e/other",
            "not a URL"
        ] {
            XCTAssertNil(UpdateChecker.releaseURL(url), url)
            let result = await check(payload(url: url))
            XCTAssertEqual(result, .invalidResponse, url)
        }
        XCTAssertNotNil(UpdateChecker.releaseURL(page))
    }
}
