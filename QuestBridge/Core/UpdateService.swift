import Foundation

/// Numeric release versions, normalized so 1.0 and 1.0.0 compare equally.
struct ReleaseVersion: Sendable, Comparable {
    private let components: [Int]
    init?(_ string: String) {
        let number = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let fields = number.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        var parsed = fields.compactMap { Int($0) }
        guard parsed.count == fields.count else { return nil }
        while parsed.count > 1 && parsed.last == 0 { parsed.removeLast() }
        components = parsed
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
struct AppRelease: Codable, Sendable, Equatable {
    let tag: String
    var version: ReleaseVersion? { ReleaseVersion(tag) }
    var displayVersion: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    // Never open a server-provided URL: the destination is always this repository.
    var pageURL: URL { URL(string: "https://github.com/mingistech/QuestBridge/releases/latest")! }
}
protocol ReleaseFetching: Sendable {
    func latestRelease() async throws -> AppRelease?
}
protocol UpdateHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
struct UpdateURLSession: UpdateHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}
struct GitHubUpdateService: ReleaseFetching {
    let client: any UpdateHTTPClient
    init(client: any UpdateHTTPClient = UpdateURLSession()) { self.client = client }
    func latestRelease() async throws -> AppRelease? {
        let url = URL(string: "https://api.github.com/repos/mingistech/QuestBridge/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QuestBridge", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.unavailable }
        if http.statusCode == 404 { return nil }
        if [403, 429].contains(http.statusCode) { throw UpdateError.rateLimited }
        guard http.statusCode == 200 else { throw UpdateError.unavailable }
        struct Payload: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool }
        guard data.count <= 2 * 1024 * 1024,
              let release = try? JSONDecoder().decode(Payload.self, from: data) else { throw UpdateError.invalidRelease }
        guard !release.draft, !release.prerelease else { return nil }
        guard ReleaseVersion(release.tag_name) != nil else { throw UpdateError.invalidRelease }
        return AppRelease(tag: release.tag_name)
    }
}
enum UpdateError: LocalizedError {
    case unavailable, rateLimited, invalidRelease, invalidInstalledVersion
    var errorDescription: String? {
        switch self {
        case .unavailable: "Couldn’t check GitHub for updates. Check your internet connection and try again."
        case .rateLimited: "GitHub is temporarily limiting update checks. Please try again later."
        case .invalidRelease: "GitHub returned release information QuestBridge couldn’t read. Please try again later."
        case .invalidInstalledVersion: "This copy of QuestBridge has no valid version number. Visit the release page to check for updates."
        }
    }
}
