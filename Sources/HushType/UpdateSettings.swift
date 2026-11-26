import Foundation

/// Daily checks are opt-in for both fresh installs and upgrades. Reading never
/// writes defaults; the last attempt is recorded before starting a request.
final class UpdateSettings {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var autoCheckEnabled: Bool {
        get { defaults.bool(forKey: "hushtype.update.autoCheckEnabled") }
        set { defaults.set(newValue, forKey: "hushtype.update.autoCheckEnabled") }
    }
    var lastCheckAttempt: Date? {
        get { defaults.object(forKey: "hushtype.update.lastCheckAttempt") as? Date }
        set { defaults.set(newValue, forKey: "hushtype.update.lastCheckAttempt") }
    }
    var lastSuccessfulCheck: Date? {
        get { defaults.object(forKey: "hushtype.update.lastSuccessfulCheck") as? Date }
        set { defaults.set(newValue, forKey: "hushtype.update.lastSuccessfulCheck") }
    }
    var lastAutomaticCheckFailed: Bool {
        get { defaults.bool(forKey: "hushtype.update.lastAutomaticCheckFailed") }
        set { defaults.set(newValue, forKey: "hushtype.update.lastAutomaticCheckFailed") }
    }
    var latestVersion: String? {
        get { defaults.string(forKey: "hushtype.update.latestVersion") }
        set { defaults.set(newValue, forKey: "hushtype.update.latestVersion") }
    }
}

enum UpdateCheckPolicy {
    static func shouldCheck(now: Date, lastAttempt: Date?, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= 24 * 60 * 60
    }

    static func availableVersion(latest: String?, current: String) -> String? {
        guard let latest, VersionChecker.compareVersions(latest, current) > 0 else { return nil }
        return latest
    }

    static func schedulingAllowed(arguments: [String], environment: [String: String], isXCTest: Bool) -> Bool {
        !isXCTest && environment["XCTestConfigurationFilePath"] == nil
            && !arguments.contains("--native-e2e") && !arguments.contains("--qa-model-switch")
    }
}
