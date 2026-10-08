import Foundation
import Testing
@testable import QuestBridgeCore

@Suite struct ReleaseVersionTests {
    @Test func comparesNumericallyAndNormalizes() throws {
        #expect(try #require(ReleaseVersion("v1.10.0")) > #require(ReleaseVersion("1.9.9")))
        #expect(ReleaseVersion("1") == ReleaseVersion("v1.0.0"))
        #expect(try #require(ReleaseVersion("2.0")) > #require(ReleaseVersion("1.999")))
        #expect(try #require(ReleaseVersion("1.0.1")) > #require(ReleaseVersion("1.0")))
    }
    @Test(arguments: ["", "latest", "1..2", "1.2.", "-1.0", "1.0-beta", "1.2.3.4.5", "1.💙", "99999999999999999999999999999"])
    func rejectsInvalidVersions(_ value: String) { #expect(ReleaseVersion(value) == nil) }
}
private actor UpdateHTTPStub: UpdateHTTPClient {
    let data: Data
    let status: Int
    private(set) var request: URLRequest?
    init(_ data: String, status: Int = 200) { self.data = Data(data.utf8); self.status = status }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
@Suite struct GitHubUpdateServiceTests {
    @Test func usesPublicAPIAndKnownReleasePage() async throws {
        let http = UpdateHTTPStub(#"{"tag_name":"v1.2.0","draft":false,"prerelease":false,"html_url":"https://malicious.example"}"#)
        let release = try #require(await GitHubUpdateService(client: http).latestRelease())
        #expect(release.displayVersion == "1.2.0")
        #expect(release.pageURL.absoluteString == "https://github.com/mingistech/QuestBridge/releases/latest")
        let request = try #require(await http.request)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/mingistech/QuestBridge/releases/latest")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 20)
    }
    @Test(arguments: [403, 429, 500])
    func reportsHTTPFailures(_ code: Int) async {
        let service = GitHubUpdateService(client: UpdateHTTPStub("{}", status: code))
        await #expect(throws: UpdateError.self) { try await service.latestRelease() }
    }
    @Test func missingReleaseIsNotANetworkError() async throws {
        #expect(try await GitHubUpdateService(client: UpdateHTTPStub("{}", status: 404)).latestRelease() == nil)
    }
    @Test(arguments: [
        #"{"tag_name":"v2.0.0","draft":true,"prerelease":false}"#,
        #"{"tag_name":"v2.0.0-beta.1","draft":false,"prerelease":true}"#
    ])
    func ignoresDraftsAndPrereleases(_ body: String) async throws {
        #expect(try await GitHubUpdateService(client: UpdateHTTPStub(body)).latestRelease() == nil)
    }
    @Test(arguments: ["not JSON", "{}", #"{"tag_name":"latest","draft":false,"prerelease":false}"#])
    func rejectsMalformedRelease(_ body: String) async {
        await #expect(throws: UpdateError.self) { try await GitHubUpdateService(client: UpdateHTTPStub(body)).latestRelease() }
    }
}
private actor ReleaseStub: ReleaseFetching {
    var release: AppRelease?
    var failure = false
    var delay: Duration = .zero
    private(set) var calls = 0
    init(tag: String? = "v1.1.0", failure: Bool = false, delay: Duration = .zero) {
        release = tag.map { AppRelease(tag: $0) }; self.failure = failure; self.delay = delay
    }
    func latestRelease() async throws -> AppRelease? {
        calls += 1
        try await Task.sleep(for: delay)
        if failure { throw UpdateError.unavailable }
        return release
    }
}
@Suite @MainActor struct UpdateCheckerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func defaults() -> (UserDefaults, String) {
        let name = "QuestBridge.UpdateTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    @Test func successfulManualCheckPostponesAutomaticCheckForAWeek() async {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        let service = ReleaseStub(tag: "v1.0.0")
        let checker = UpdateChecker(installedVersion: "1.0.0", service: service, defaults: store)
        await checker.check(manual: true, now: now)
        #expect(checker.notice?.title == "You’re up to date")
        #expect(!checker.automaticCheckIsDue(at: now.addingTimeInterval(UpdateChecker.weeklyInterval - 1)))
        #expect(checker.automaticCheckIsDue(at: now.addingTimeInterval(UpdateChecker.weeklyInterval)))
        let restored = UpdateChecker(installedVersion: "1.0.0", service: service, defaults: store)
        #expect(restored.lastChecked == now)
        #expect(!restored.automaticCheckIsDue(at: now.addingTimeInterval(3600)))
        await restored.check(manual: false, now: now.addingTimeInterval(3600))
        #expect(await service.calls == 1)
        await restored.check(manual: true, now: now.addingTimeInterval(3600))
        #expect(await service.calls == 2)
    }
    @Test func automaticUpdateNoticeIsDeduplicatedButManualChecksAlwaysReport() async {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        let service = ReleaseStub()
        let checker = UpdateChecker(installedVersion: "1.0.0", service: service, defaults: store)
        await checker.check(manual: false, now: now)
        #expect(checker.notice?.release?.tag == "v1.1.0")
        checker.dismissNotice()
        let restored = UpdateChecker(installedVersion: "1.0.0", service: service, defaults: store)
        #expect(restored.availableRelease?.tag == "v1.1.0")
        await restored.check(manual: false, now: now.addingTimeInterval(UpdateChecker.weeklyInterval))
        #expect(restored.notice == nil)
        await restored.check(manual: true, now: now.addingTimeInterval(UpdateChecker.weeklyInterval + 1))
        #expect(restored.notice?.release?.tag == "v1.1.0")
    }
    @Test func automaticFailureRetriesWithoutResettingSuccessfulDate() async {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        let last = now.addingTimeInterval(-UpdateChecker.weeklyInterval)
        store.set(last, forKey: "updates.lastChecked")
        let checker = UpdateChecker(installedVersion: "1.0.0", service: ReleaseStub(failure: true), defaults: store)
        await checker.check(manual: false, now: now)
        #expect(checker.notice == nil)
        #expect(checker.lastChecked == last)
        #expect(!checker.automaticCheckIsDue(at: now.addingTimeInterval(60)))
        #expect(checker.automaticCheckIsDue(at: now.addingTimeInterval(3600)))
        await checker.check(manual: true, now: now)
        #expect(checker.notice?.title == "Unable to Check for Updates")
    }
    @Test func concurrentChecksMakeOnlyOneRequest() async throws {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        let service = ReleaseStub(delay: .milliseconds(100))
        let checker = UpdateChecker(installedVersion: "1.0.0", service: service, defaults: store)
        let first = Task { await checker.check(manual: true, now: now) }
        while !checker.isChecking { await Task.yield() }
        await checker.check(manual: false, now: now)
        await first.value
        #expect(await service.calls == 1)
    }
    @Test func cancelledCheckDoesNotPostponeRetryOrShowError() async {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        let checker = UpdateChecker(installedVersion: "1.0.0", service: ReleaseStub(delay: .seconds(10)), defaults: store)
        let task = Task { await checker.check(manual: true, now: now) }
        while !checker.isChecking { await Task.yield() }
        task.cancel(); await task.value
        #expect(checker.notice == nil && checker.lastChecked == nil && !checker.isChecking)
        #expect(checker.automaticCheckIsDue(at: now))
    }
    @Test func noReleaseAndOlderVersionsDoNotAnnounceAnUpdate() async {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        for tag in [nil, "v0.9.0", "v1.0.0"] as [String?] {
            let checker = UpdateChecker(installedVersion: "1.0.0", service: ReleaseStub(tag: tag), defaults: store)
            await checker.check(manual: true, now: now)
            #expect(checker.availableRelease == nil)
            #expect(checker.notice?.release == nil)
        }
    }
    @Test func aFutureClockDoesNotSuppressUpdatesIndefinitely() {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        store.set(now.addingTimeInterval(86400), forKey: "updates.lastChecked")
        store.set(now.addingTimeInterval(86400), forKey: "updates.lastAttempt")
        let checker = UpdateChecker(installedVersion: "1.0.0", defaults: store)
        #expect(checker.automaticCheckIsDue(at: now))
    }
}
