import AppKit
import os
import Combine

private let updateCheckLog = Logger(subsystem: "com.felix.hushtype", category: "updates")

/// Manual checks ask for consent unless the user enabled daily checks.
/// Automatic checks are silent and begin only after onboarding completes.
@MainActor
final class UpdateCheckCoordinator: NSObject, ObservableObject {
    static let shared = UpdateCheckCoordinator()
    static let aboutMenuIdentifier = NSUserInterfaceItemIdentifier("status-about")
    static let releasesURL = URL(string: "https://github.com/felixfu824/Lamitype/releases/latest")!

    @Published private(set) var autoCheckEnabled: Bool
    @Published private(set) var lastCheckAttempt: Date?
    @Published private(set) var lastSuccessfulCheck: Date?
    @Published private(set) var availableVersion: String?
    @Published private(set) var lastAutomaticCheckFailed: Bool

    var lastFailedAutomaticAttempt: Date? {
        guard lastAutomaticCheckFailed, let attempt = lastCheckAttempt,
              lastSuccessfulCheck.map({ attempt > $0 }) ?? true else { return nil }
        return attempt
    }

    /// A manual click can claim an automatic request without issuing a second
    /// fetch. Its independent task survives cancellation of the schedule.
    @MainActor
    private final class Request {
        let id = UUID()
        let task: Task<VersionChecker.Result, Error>
        var claimedByManual = false
        init(fetcher: @escaping () async throws -> VersionChecker.Result) {
            task = Task { try await fetcher() }
        }
    }

    private let settings: UpdateSettings
    private let fetcher: () async throws -> VersionChecker.Result
    private let now: () -> Date
    private let currentVersion: String
    private let schedulingAllowed: () -> Bool
    private let delay: @MainActor (TimeInterval) async throws -> Void
    private let manualConsent: @MainActor () -> Bool
    private let manualOutcome: (@MainActor (Result<VersionChecker.Result, Error>) -> Void)?
    private var scheduleGeneration = UUID()
    private var activeCheckID: UUID?
    private var automaticTaskID: UUID?
    private var automaticRequest: Request?
    private var manualCheckID: UUID?
    private var manualRequest: Request?
    private var manualTask: Task<Void, Never>?
    private var isChecking: Bool { activeCheckID != nil || manualCheckID != nil }
    private var scheduleStarted = false
    private var launchTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var wakeDelayPending = false
    private var automaticTask: Task<Void, Never>?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(settings: UpdateSettings = UpdateSettings(),
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
         now: @escaping () -> Date = Date.init,
         fetcher: @escaping () async throws -> VersionChecker.Result = { try await VersionChecker.check() },
         schedulingAllowed: @escaping () -> Bool = {
             UpdateCheckPolicy.schedulingAllowed(arguments: CommandLine.arguments,
                 environment: ProcessInfo.processInfo.environment,
                 isXCTest: NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil)
         },
         delay: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         manualConsent: @escaping @MainActor () -> Bool = { UpdateCheckCoordinator.makeConsentAlert().runModal() == .alertSecondButtonReturn },
         manualOutcome: (@MainActor (Result<VersionChecker.Result, Error>) -> Void)? = nil) {
        self.settings = settings
        self.currentVersion = currentVersion
        self.now = now
        self.fetcher = fetcher
        self.schedulingAllowed = schedulingAllowed
        self.delay = delay
        self.manualConsent = manualConsent
        self.manualOutcome = manualOutcome
        autoCheckEnabled = settings.autoCheckEnabled
        lastCheckAttempt = settings.lastCheckAttempt
        lastSuccessfulCheck = settings.lastSuccessfulCheck
        lastAutomaticCheckFailed = settings.lastAutomaticCheckFailed
        availableVersion = UpdateCheckPolicy.availableVersion(latest: Self.displayLatestVersion(settings.latestVersion), current: currentVersion)
        super.init()
    }

    private static func displayLatestVersion(_ latest: String?) -> String? {
        #if DEBUG
        if let version = ProcessInfo.processInfo.environment["LAMITYPE_DEBUG_LATEST_VERSION"] { return version }
        #endif
        return latest
    }

    /// Called only after OnboardingManager.runIfNeeded() returns false.
    func startAfterOnboarding() {
        guard !scheduleStarted, schedulingAllowed() else { return }
        scheduleStarted = true
        if autoCheckEnabled { installSchedule() }
    }

    func setAutoCheckEnabled(_ enabled: Bool) {
        guard enabled != autoCheckEnabled else { return }
        autoCheckEnabled = enabled
        settings.autoCheckEnabled = enabled
        cancelSchedule()
        guard enabled, scheduleStarted else { return }
        installSchedule()
        beginAutomaticCheck(force: true)
    }

    private func beginAutomaticCheck(force: Bool = false) {
        let taskID = UUID()
        automaticTaskID = taskID
        automaticTask = Task { [weak self] in
            await self?.performAutomaticCheck(force: force)
            guard let self, self.automaticTaskID == taskID else { return }
            self.automaticTask = nil
            self.automaticTaskID = nil
        }
    }

    private func installSchedule() {
        launchTask = Task { [weak self, delay] in
            do { try await delay(60) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.performAutomaticCheck()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateAutomaticCheck() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    func handleWake() {
        guard scheduleStarted, autoCheckEnabled else { return }
        wakeTask?.cancel()
        wakeDelayPending = true
        let generation = scheduleGeneration
        wakeTask = Task { [weak self, delay] in
            do { try await delay(60) } catch { return }
            guard !Task.isCancelled, let self, self.scheduleGeneration == generation else { return }
            self.wakeDelayPending = false
            self.evaluateAutomaticCheck()
        }
    }

    private func cancelSchedule() {
        scheduleGeneration = UUID()
        // A claimed fetch belongs to the user's manual action. Turning daily
        // checks off must neither cancel that fetch nor discard its feedback.
        if let request = automaticRequest, !request.claimedByManual { request.task.cancel() }
        automaticRequest = nil
        activeCheckID = nil
        automaticTaskID = nil
        launchTask?.cancel(); launchTask = nil
        wakeTask?.cancel(); wakeTask = nil
        wakeDelayPending = false
        automaticTask?.cancel(); automaticTask = nil
        timer?.invalidate(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func evaluateAutomaticCheck() {
        guard scheduleStarted, autoCheckEnabled, !wakeDelayPending, !isChecking, automaticTask == nil else { return }
        beginAutomaticCheck()
    }

    #if DEBUG
    var hasScheduleForTesting: Bool { timer != nil && wakeObserver != nil && launchTask != nil }
    var isCheckingForTesting: Bool { isChecking }
    var automaticTaskForTesting: Task<Void, Never>? { automaticTask }
    var automaticTaskIDForTesting: UUID? { automaticTaskID }
    var manualTaskForTesting: Task<Void, Never>? { manualTask }
    var wakeTaskForTesting: Task<Void, Never>? { wakeTask }
    #endif

    func performAutomaticCheck(force: Bool = false) async {
        guard !Task.isCancelled, !wakeDelayPending, !isChecking, autoCheckEnabled,
              force || UpdateCheckPolicy.shouldCheck(now: now(), lastAttempt: lastCheckAttempt, enabled: autoCheckEnabled)
        else { return }
        let generation = scheduleGeneration
        let request = Request(fetcher: fetcher)
        activeCheckID = request.id
        automaticRequest = request
        recordAttempt()
        defer {
            if activeCheckID == request.id {
                activeCheckID = nil
                automaticRequest = nil
            }
        }
        do {
            let result = try await request.task.value
            guard !Task.isCancelled, autoCheckEnabled, !request.claimedByManual,
                  scheduleGeneration == generation, activeCheckID == request.id else { return }
            storeResult(result)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), autoCheckEnabled, !request.claimedByManual,
                  scheduleGeneration == generation, activeCheckID == request.id else { return }
            settings.lastAutomaticCheckFailed = true
            lastAutomaticCheckFailed = true
            updateCheckLog.info("Automatic version check failed")
        }
    }

    private func recordAttempt() {
        settings.lastAutomaticCheckFailed = false
        lastAutomaticCheckFailed = false
        let attempt = now()
        settings.lastCheckAttempt = attempt
        lastCheckAttempt = attempt
    }

    private func storeResult(_ result: VersionChecker.Result) {
        settings.lastAutomaticCheckFailed = false
        lastAutomaticCheckFailed = false
        let success = now()
        settings.lastSuccessfulCheck = success
        lastSuccessfulCheck = success
        settings.latestVersion = result.latestVersion
        availableVersion = UpdateCheckPolicy.availableVersion(latest: Self.displayLatestVersion(result.latestVersion), current: currentVersion)
    }

    func checkForUpdates() {
        guard manualCheckID == nil else { return }
        if let request = automaticRequest {
            request.claimedByManual = true
            startManualCheck(request, recordNewAttempt: false)
            return
        }
        if !autoCheckEnabled, !manualConsent() { return }
        startManualCheck(Request(fetcher: fetcher), recordNewAttempt: true)
    }

    private func startManualCheck(_ request: Request, recordNewAttempt: Bool) {
        let manualID = UUID()
        manualCheckID = manualID
        manualRequest = request
        if recordNewAttempt { recordAttempt() }
        manualTask = Task { [weak self] in
            let outcome: Result<VersionChecker.Result, Error>
            do { outcome = .success(try await request.task.value) }
            catch { outcome = .failure(error) }
            guard let self, self.manualCheckID == manualID else { return }
            if case .success(let result) = outcome { self.storeResult(result) }
            self.manualCheckID = nil
            self.manualRequest = nil
            self.manualTask = nil
            self.presentManualOutcome(outcome)
        }
    }

    private func presentManualOutcome(_ outcome: Result<VersionChecker.Result, Error>) {
        if let manualOutcome { manualOutcome(outcome); return }
        switch outcome {
        case .success(let result):
            if result.isUpToDate { showUpToDate(version: result.currentVersion) }
            else { showUpdateAvailable(version: result.latestVersion, url: Self.releasesURL) }
        case .failure(let error): showCheckError(error)
        }
    }

    // One small menu integration owns both insertion and refresh on menu open.
    func refreshMenuItem(in menu: NSMenu) {
        let identifier = NSUserInterfaceItemIdentifier("daily-update-available")
        let separatorID = NSUserInterfaceItemIdentifier("daily-update-separator")
        for existing in menu.items where existing.identifier == identifier || existing.identifier == separatorID {
            menu.removeItem(existing)
        }
        guard let availableVersion,
              let aboutIndex = menu.items.firstIndex(where: { $0.identifier == Self.aboutMenuIdentifier }) else { return }
        let item = NSMenuItem(title: L10n.format("update.daily.menu", "Update Available: v%1$@…", arguments: [availableVersion]),
                              action: #selector(openReleasePage), keyEquivalent: "")
        item.identifier = identifier
        item.target = self
        let separator = NSMenuItem.separator()
        separator.identifier = separatorID
        menu.insertItem(item, at: aboutIndex)
        menu.insertItem(separator, at: aboutIndex + 1)
    }

    @objc private func openReleasePage() { NSWorkspace.shared.open(Self.releasesURL) }

    static func makeConsentAlert() -> NSAlert {
        let consent = NSAlert()
        consent.messageText = L10n.string(
            "alert.update_consent.title",
            fallback: "Connect to GitHub?"
        )
        consent.informativeText = L10n.string(
            "alert.update_consent.message",
            fallback: "Lamitype will connect to GitHub to check for new releases.\n\nNo personal data is sent; only a public API call is made to compare version numbers."
        )
        consent.alertStyle = .informational
        consent.icon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        consent.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        consent.addButton(withTitle: L10n.string(
            "alert.update_consent.check_now",
            fallback: "Check Now"
        ))
        return consent
    }

    private func showUpToDate(version: String) {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.update.up_to_date.title",
            fallback: "Up to Date"
        )
        alert.informativeText = L10n.format(
            "alert.update.up_to_date.message",
            "You're running the latest version (v%1$@).",
            arguments: [version]
        )
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }

    private func showUpdateAvailable(version: String, url: URL?) {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.update.available.title",
            fallback: "Update Available"
        )
        alert.informativeText = L10n.format(
            "alert.update.available.message",
            "A new version is available: v%1$@\n\nYou can download it from the GitHub Releases page.",
            arguments: [version]
        )
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: L10n.string(
            "alert.update.view_github",
            fallback: "View on GitHub"
        ))
        alert.addButton(withTitle: L10n.string("common.button.later", fallback: "Later"))

        if alert.runModal() == .alertFirstButtonReturn {
            let destination = url ?? URL(string: "https://github.com/felixfu824/lamitype/releases")
            if let destination {
                NSWorkspace.shared.open(destination)
            }
        }
    }

    private func showCheckError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.update.error.title",
            fallback: "Could Not Check for Updates"
        )
        alert.alertStyle = .warning
        alert.icon = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        alert.informativeText = L10n.format(
            "alert.update.error.message",
            "Unable to connect to GitHub.\n\n%1$@\n\nCheck your internet connection and try again.",
            arguments: [error.localizedDescription]
        )
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }
}
