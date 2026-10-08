import Foundation
import Observation

struct UpdateNotice: Sendable, Equatable {
    let title: String
    let message: String
    var release: AppRelease?
}

@MainActor @Observable final class UpdateChecker {
    static let weeklyInterval: TimeInterval = 7 * 24 * 60 * 60
    static let failureRetryInterval: TimeInterval = 60 * 60
    let installedVersion: String
    private(set) var isChecking = false
    private(set) var lastChecked: Date?
    private(set) var availableRelease: AppRelease?
    var notice: UpdateNotice?
    private var lastAttempt: Date?
    private let service: any ReleaseFetching
    private let defaults: UserDefaults
    private var monitoring = false

    init(installedVersion: String, service: any ReleaseFetching = GitHubUpdateService(), defaults: UserDefaults = .standard) {
        self.installedVersion = installedVersion
        self.service = service
        self.defaults = defaults
        lastChecked = defaults.object(forKey: "updates.lastChecked") as? Date
        lastAttempt = defaults.object(forKey: "updates.lastAttempt") as? Date
        if let data = defaults.data(forKey: "updates.latestRelease"),
           let cached = try? JSONDecoder().decode(AppRelease.self, from: data),
           let remote = cached.version, let local = ReleaseVersion(installedVersion), remote > local {
            availableRelease = cached
        }
    }
    func automaticCheckIsDue(at now: Date) -> Bool {
        // Future dates (e.g. after a clock correction) must not suppress checks forever.
        if let lastChecked, now >= lastChecked, now.timeIntervalSince(lastChecked) < Self.weeklyInterval { return false }
        if let lastAttempt, now >= lastAttempt, now.timeIntervalSince(lastAttempt) < Self.failureRetryInterval { return false }
        return true
    }
    func check(manual: Bool, now: Date = Date()) async {
        guard !isChecking, manual || automaticCheckIsDue(at: now) else { return }
        isChecking = true
        defer { isChecking = false }
        let previousAttempt = lastAttempt
        lastAttempt = now
        defaults.set(now, forKey: "updates.lastAttempt")
        do {
            guard let local = ReleaseVersion(installedVersion) else { throw UpdateError.invalidInstalledVersion }
            let release = try await service.latestRelease()
            try Task.checkCancellation()
            lastChecked = now
            defaults.set(now, forKey: "updates.lastChecked")
            if let release { defaults.set(try JSONEncoder().encode(release), forKey: "updates.latestRelease") }
            else { defaults.removeObject(forKey: "updates.latestRelease") }
            if let release, let remote = release.version, remote > local {
                availableRelease = release
                if manual || defaults.string(forKey: "updates.lastNotifiedTag") != release.tag {
                    notice = UpdateNotice(title: "QuestBridge \(release.displayVersion) is available",
                                          message: "You’re using version \(installedVersion). Open the GitHub release page to download the new version.", release: release)
                }
            } else {
                availableRelease = nil
                if manual {
                    notice = release == nil
                        ? UpdateNotice(title: "No Published Releases", message: "No public stable release is available on GitHub yet. Please check again later.")
                        : UpdateNotice(title: "You’re up to date", message: "You’re running QuestBridge \(installedVersion). No newer release is available.")
                }
            }
        } catch is CancellationError {
            lastAttempt = previousAttempt
            defaults.set(previousAttempt, forKey: "updates.lastAttempt")
        } catch {
            // Automatic failures stay quiet and retry in an hour, rather than postponing a full week.
            if manual {
                let message = (error as? UpdateError)?.localizedDescription ?? UpdateError.unavailable.localizedDescription
                notice = UpdateNotice(title: "Unable to Check for Updates", message: message)
            }
        }
    }
    func dismissNotice() {
        if let release = notice?.release { defaults.set(release.tag, forKey: "updates.lastNotifiedTag") }
        notice = nil
    }
    /// Runs only while the app is open; launch/foreground checks catch up after sleep or time away.
    func monitor() async {
        guard !monitoring else { return }
        monitoring = true
        defer { monitoring = false }
        while !Task.isCancelled {
            await check(manual: false)
            do { try await Task.sleep(for: .seconds(3600)) } catch { return }
        }
    }
}
