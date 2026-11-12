import Foundation

/// Decimal components stay as strings so even large release numbers compare without overflow.
public struct ReleaseVersion: Comparable, Equatable {
    private let components: [String]

    public init?(_ text: String, allowingTagPrefix: Bool = false) {
        var value = text
        if allowingTagPrefix, value.first == "v" || value.first == "V" { value.removeFirst() }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        var normalized = parts.map { part -> String in
            let digits = part.drop(while: { $0 == "0" })
            return digits.isEmpty ? "0" : String(digits)
        }
        while normalized.count > 1 && normalized.last == "0" { normalized.removeLast() }
        components = normalized
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let a = index < lhs.components.count ? lhs.components[index] : "0"
            let b = index < rhs.components.count ? rhs.components[index] : "0"
            if a.count != b.count { return a.count < b.count }
            if a != b { return a.lexicographicallyPrecedes(b) }
        }
        return false
    }
}

public enum UpdateCheckResult: Equatable {
    case available(version: String, url: URL)
    case upToDate
    case noRelease
    case rateLimited
    case networkError
    case invalidResponse
}

public protocol UpdateTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Reject redirects rather than following a server-provided location to another endpoint.
private final class ReleaseTransport: NSObject, UpdateTransport, URLSessionTaskDelegate {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct UpdateChecker {
    public static let endpoint = URL(string: "https://api.github.com/repos/kimipooh/folder-merger-for-macos/releases/latest")!
    private let transport: any UpdateTransport

    public init(transport: (any UpdateTransport)? = nil) {
        self.transport = transport ?? ReleaseTransport()
    }

    public static func releaseURL(_ text: String) -> URL? {
        let prefix = "https://github.com/kimipooh/folder-merger-for-macos/releases/"
        guard text.hasPrefix(prefix), let parts = URLComponents(string: text),
              parts.scheme == "https", parts.host == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.percentEncodedPath.hasPrefix("/kimipooh/folder-merger-for-macos/releases/"),
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let url = parts.url else { return nil }
        return url
    }

    public func check(currentVersion: String) async -> UpdateCheckResult {
        guard let current = ReleaseVersion(currentVersion) else { return .invalidResponse }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FolderMerger/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch { return .networkError }
        guard let http = response as? HTTPURLResponse else { return .invalidResponse }
        if http.statusCode == 403 || http.statusCode == 429 || http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            return .rateLimited
        }
        if http.statusCode == 404 { return .noRelease }
        guard http.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease,
              let version = ReleaseVersion(release.tag_name, allowingTagPrefix: true),
              let url = Self.releaseURL(release.html_url) else { return .invalidResponse }
        return version > current ? .available(version: release.tag_name, url: url) : .upToDate
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
    }
}
