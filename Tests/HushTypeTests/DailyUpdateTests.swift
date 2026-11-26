import XCTest
import AppKit
@testable import HushType

@MainActor
private final class PendingUpdateFetch {
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<VersionChecker.Result, Error>] = [:]

    func fetch() async throws -> VersionChecker.Result {
        let index = calls
        calls += 1
        // Deliberately ignores cancellation to exercise late completions.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func complete(_ index: Int, version: String = "2") {
        pending.removeValue(forKey: index)?.resume(returning: VersionChecker.Result(
            currentVersion: "1", latestVersion: version, isUpToDate: false, releaseURL: nil))
    }

    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: URLError(.notConnectedToInternet))
    }

    func finishAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class PendingUpdateDelay {
    private(set) var durations: [TimeInterval] = []
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    func wait(_ seconds: TimeInterval) async throws {
        let index = durations.count
        durations.append(seconds)
        try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func resume(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
    func finishAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
final class DailyUpdateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testDueRuleAndClockRollback() {
        XCTAssertFalse(UpdateCheckPolicy.shouldCheck(now: now, lastAttempt: nil, enabled: false))
        XCTAssertTrue(UpdateCheckPolicy.shouldCheck(now: now, lastAttempt: nil, enabled: true))
        for hours in [0.0, 20, 23.999] {
            XCTAssertFalse(UpdateCheckPolicy.shouldCheck(now: now, lastAttempt: now.addingTimeInterval(-hours * 3600), enabled: true))
        }
        XCTAssertTrue(UpdateCheckPolicy.shouldCheck(now: now, lastAttempt: now.addingTimeInterval(-86400), enabled: true))
        XCTAssertTrue(UpdateCheckPolicy.shouldCheck(now: now, lastAttempt: now.addingTimeInterval(1), enabled: true))
    }

    func testSchedulingDisabledForAutomation() {
        XCTAssertTrue(UpdateCheckPolicy.schedulingAllowed(arguments: [], environment: [:], isXCTest: false))
        for flag in ["--native-e2e", "--qa-model-switch"] {
            XCTAssertFalse(UpdateCheckPolicy.schedulingAllowed(arguments: [flag], environment: [:], isXCTest: false))
        }
        XCTAssertFalse(UpdateCheckPolicy.schedulingAllowed(arguments: [], environment: [:], isXCTest: true))
        XCTAssertFalse(UpdateCheckPolicy.schedulingAllowed(arguments: [], environment: ["XCTestConfigurationFilePath": "test"], isXCTest: false))
    }

    @MainActor
    func testFreshInstallAndUpgradeAreOffWithoutWrites() throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateTests")
        let defaults = suite.defaults
        let settings = UpdateSettings(defaults: defaults)
        XCTAssertFalse(settings.autoCheckEnabled)
        XCTAssertTrue(defaults.persistentDomain(forName: suite.name)?.isEmpty ?? true)
        defaults.set("existing preference", forKey: "hushtype.legacy")
        _ = UpdateCheckCoordinator(settings: settings, currentVersion: "1", fetcher: { XCTFail("Unexpected fetch"); throw CancellationError() })
        XCTAssertFalse(settings.autoCheckEnabled)
        XCTAssertNil(defaults.object(forKey: "hushtype.update.autoCheckEnabled"))
    }

    @MainActor
    func testAutomaticResultsAreQuietAndAttemptsPrecedeFetch() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateTests")
        let defaults = suite.defaults
        let settings = UpdateSettings(defaults: defaults)
        settings.autoCheckEnabled = true
        var calls = 0
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { self.now }, fetcher: {
            calls += 1
            XCTAssertEqual(settings.lastCheckAttempt, self.now)
            return VersionChecker.Result(currentVersion: "1", latestVersion: "2", isUpToDate: false, releaseURL: URL(string: "https://untrusted.invalid"))
        })
        await coordinator.performAutomaticCheck()
        XCTAssertEqual(coordinator.availableVersion, "2")
        let menu = NSMenu()
        let about = NSMenuItem(title: "About", action: nil, keyEquivalent: "")
        about.identifier = UpdateCheckCoordinator.aboutMenuIdentifier
        menu.addItem(about)
        coordinator.refreshMenuItem(in: menu)
        coordinator.refreshMenuItem(in: menu)
        XCTAssertEqual(menu.numberOfItems, 3)
        XCTAssertTrue(menu.items[0].target === coordinator)
        await coordinator.performAutomaticCheck()
        XCTAssertEqual(calls, 1)
        coordinator.setAutoCheckEnabled(false)
        await coordinator.performAutomaticCheck(force: true)
        XCTAssertEqual(calls, 1)
        // Reopening after installing that version removes the old notice.
        let updated = UpdateCheckCoordinator(settings: settings, currentVersion: "2", fetcher: {
            XCTFail("Unexpected fetch"); throw CancellationError()
        })
        updated.refreshMenuItem(in: menu)
        XCTAssertEqual(menu.numberOfItems, 1)
        XCTAssertEqual(UpdateCheckCoordinator.releasesURL.absoluteString, "https://github.com/felixfu824/Lamitype/releases/latest")
    }

    @MainActor
    func testAutomaticErrorsAndUpToDateAreSilentAndStoredResultRevalidated() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateTests")
        let defaults = suite.defaults
        let settings = UpdateSettings(defaults: defaults)
        settings.autoCheckEnabled = true
        settings.latestVersion = "1"
        for current in ["1", "2"] {
            let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: current, fetcher: { throw CancellationError() })
            XCTAssertNil(coordinator.availableVersion)
            await coordinator.performAutomaticCheck(force: true)
            XCTAssertNil(coordinator.availableVersion)
            XCTAssertNotNil(settings.lastCheckAttempt)
        }
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "2", fetcher: {
            VersionChecker.Result(currentVersion: "2", latestVersion: "1", isUpToDate: true, releaseURL: nil)
        })
        await coordinator.performAutomaticCheck(force: true)
        XCTAssertNil(coordinator.availableVersion)
    }

    func testFailedAutomaticAttemptIsQuietPersistedAndClearsOnRetryOrSuccess() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateFailureStatus")
        let settings = UpdateSettings(defaults: suite.defaults)
        settings.autoCheckEnabled = true
        settings.lastSuccessfulCheck = now.addingTimeInterval(-86401)
        let probe = PendingUpdateFetch()
        defer { probe.finishAll() }
        var clock = now
        var manualOutcomes = 0
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { clock },
            fetcher: { try await probe.fetch() }, manualOutcome: { _ in manualOutcomes += 1 })
        let first = Task { await coordinator.performAutomaticCheck() }
        try await waitForCalls(probe, 1)
        XCTAssertNil(coordinator.lastFailedAutomaticAttempt, "An in-flight attempt is not a failure")
        probe.fail(0)
        await first.value
        XCTAssertEqual(coordinator.lastFailedAutomaticAttempt, now)
        XCTAssertTrue(settings.lastAutomaticCheckFailed)
        XCTAssertEqual(manualOutcomes, 0, "Automatic failures stay quiet")
        let reopened = UpdateCheckCoordinator(settings: settings, currentVersion: "1", fetcher: {
            XCTFail("Reading failure status must not fetch"); throw CancellationError()
        })
        XCTAssertEqual(reopened.lastFailedAutomaticAttempt, now)
        clock = now.addingTimeInterval(86401)
        let retry = Task { await coordinator.performAutomaticCheck() }
        try await waitForCalls(probe, 2)
        XCTAssertNil(coordinator.lastFailedAutomaticAttempt, "Do not label the new pending attempt as failed")
        probe.complete(1)
        await retry.value
        XCTAssertEqual(coordinator.lastSuccessfulCheck, clock)
        XCTAssertNil(coordinator.lastFailedAutomaticAttempt)
        XCTAssertFalse(settings.lastAutomaticCheckFailed)
        clock = clock.addingTimeInterval(1)
        coordinator.checkForUpdates()
        let manual = try XCTUnwrap(coordinator.manualTaskForTesting)
        try await waitForCalls(probe, 3)
        probe.fail(2)
        await manual.value
        XCTAssertEqual(manualOutcomes, 1)
        XCTAssertNil(coordinator.lastFailedAutomaticAttempt, "Manual failures use their existing explicit feedback")
    }

    func testCancelledOrStaleAutomaticAttemptDoesNotBecomeFailureStatus() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateCancelledFailureStatus")
        let settings = UpdateSettings(defaults: suite.defaults)
        settings.autoCheckEnabled = true
        let probe = PendingUpdateFetch()
        defer { probe.finishAll() }
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { self.now },
                                                 fetcher: { try await probe.fetch() })
        let request = Task { await coordinator.performAutomaticCheck() }
        try await waitForCalls(probe, 1)
        coordinator.setAutoCheckEnabled(false)
        probe.fail(0)
        await request.value
        XCTAssertNil(coordinator.lastFailedAutomaticAttempt)
        XCTAssertFalse(settings.lastAutomaticCheckFailed)
        settings.autoCheckEnabled = true
        let cancelled = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { self.now },
                                               fetcher: { throw CancellationError() })
        await cancelled.performAutomaticCheck(force: true)
        XCTAssertNil(cancelled.lastFailedAutomaticAttempt)
        XCTAssertFalse(settings.lastAutomaticCheckFailed)
        // A persisted failure is relevant only when its attempt is newer than success.
        settings.lastAutomaticCheckFailed = true
        for attempt in [now, now.addingTimeInterval(-1)] {
            settings.lastCheckAttempt = attempt
            settings.lastSuccessfulCheck = now
            let oldFailure = UpdateCheckCoordinator(settings: settings, currentVersion: "1")
            XCTAssertNil(oldFailure.lastFailedAutomaticAttempt)
        }
    }

    private func waitForCalls(_ probe: PendingUpdateFetch, _ count: Int) async throws {
        for _ in 0..<1000 {
            if probe.calls >= count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) injected fetch calls, got \(probe.calls)")
        throw CancellationError()
    }

    func testEnablingForcesExactlyOneImmediateCheckAndInstallsSchedule() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateToggle")
        let settings = UpdateSettings(defaults: suite.defaults)
        settings.lastCheckAttempt = now // Force must bypass the recent attempt.
        let probe = PendingUpdateFetch()
        var clock = now
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { clock },
            fetcher: { try await probe.fetch() }, schedulingAllowed: { true })
        defer { coordinator.setAutoCheckEnabled(false); probe.finishAll() }
        coordinator.startAfterOnboarding()
        XCTAssertFalse(coordinator.hasScheduleForTesting)
        coordinator.setAutoCheckEnabled(true)
        XCTAssertTrue(coordinator.hasScheduleForTesting)
        let task = try XCTUnwrap(coordinator.automaticTaskForTesting)
        try await waitForCalls(probe, 1)
        XCTAssertEqual(settings.lastCheckAttempt, now)
        coordinator.setAutoCheckEnabled(true)
        coordinator.evaluateAutomaticCheck()
        XCTAssertEqual(probe.calls, 1)
        clock = now.addingTimeInterval(5)
        probe.complete(0)
        await task.value
        XCTAssertEqual(settings.lastSuccessfulCheck, clock)
        XCTAssertEqual(coordinator.lastSuccessfulCheck, clock)
        XCTAssertFalse(coordinator.isCheckingForTesting)
        XCTAssertNil(coordinator.automaticTaskForTesting)
    }

    func testOffCancelsInFlightFetchAndPreventsFurtherRequestsOrLateResults() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateCancel")
        let settings = UpdateSettings(defaults: suite.defaults)
        let probe = PendingUpdateFetch()
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { self.now },
            fetcher: { try await probe.fetch() }, schedulingAllowed: { true })
        defer { coordinator.setAutoCheckEnabled(false); probe.finishAll() }
        coordinator.startAfterOnboarding()
        coordinator.setAutoCheckEnabled(true)
        let task = try XCTUnwrap(coordinator.automaticTaskForTesting)
        try await waitForCalls(probe, 1)
        coordinator.setAutoCheckEnabled(false)
        XCTAssertTrue(task.isCancelled)
        XCTAssertFalse(coordinator.hasScheduleForTesting)
        XCTAssertFalse(coordinator.isCheckingForTesting)
        coordinator.evaluateAutomaticCheck()
        await coordinator.performAutomaticCheck(force: true)
        probe.complete(0, version: "99")
        await task.value
        XCTAssertEqual(probe.calls, 1)
        XCTAssertNil(coordinator.availableVersion)
        XCTAssertNil(settings.latestVersion)
        XCTAssertNil(settings.lastSuccessfulCheck)
        XCTAssertNil(coordinator.automaticTaskForTesting)
    }

    func testQuickOffOnStartsReplacementAndOldCompletionCannotClearIt() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateGeneration")
        let settings = UpdateSettings(defaults: suite.defaults)
        let probe = PendingUpdateFetch()
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { self.now },
            fetcher: { try await probe.fetch() }, schedulingAllowed: { true })
        defer { coordinator.setAutoCheckEnabled(false); probe.finishAll() }
        coordinator.startAfterOnboarding()
        coordinator.setAutoCheckEnabled(true)
        let first = try XCTUnwrap(coordinator.automaticTaskForTesting)
        try await waitForCalls(probe, 1)
        coordinator.setAutoCheckEnabled(false)
        coordinator.setAutoCheckEnabled(true)
        let second = try XCTUnwrap(coordinator.automaticTaskForTesting)
        let secondID = coordinator.automaticTaskIDForTesting
        try await waitForCalls(probe, 2)
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(coordinator.isCheckingForTesting)
        probe.complete(0, version: "99")
        await first.value
        XCTAssertNotNil(coordinator.automaticTaskForTesting)
        XCTAssertEqual(coordinator.automaticTaskIDForTesting, secondID)
        XCTAssertTrue(coordinator.isCheckingForTesting)
        XCTAssertNil(coordinator.availableVersion)
        XCTAssertNil(settings.lastSuccessfulCheck)
        probe.complete(1, version: "2")
        await second.value
        XCTAssertEqual(coordinator.availableVersion, "2")
        XCTAssertEqual(settings.lastSuccessfulCheck, now)
        XCTAssertFalse(coordinator.isCheckingForTesting)
        XCTAssertNil(coordinator.automaticTaskForTesting)
        XCTAssertEqual(probe.calls, 2)
    }

    func testCoordinatorStartAfterOnboardingIsNoOpUnderXCTest() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateXCTest")
        let settings = UpdateSettings(defaults: suite.defaults)
        settings.autoCheckEnabled = true
        var calls = 0
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", fetcher: {
            calls += 1
            XCTFail("XCTest startup must not fetch")
            throw CancellationError()
        })
        coordinator.startAfterOnboarding()
        coordinator.evaluateAutomaticCheck()
        coordinator.setAutoCheckEnabled(false)
        coordinator.setAutoCheckEnabled(true)
        await Task.yield()
        XCTAssertFalse(coordinator.hasScheduleForTesting)
        XCTAssertNil(coordinator.automaticTaskForTesting)
        XCTAssertNil(settings.lastCheckAttempt)
        XCTAssertEqual(calls, 0)
    }

    func testFailedAttemptDoesNotInventOrAdvanceLastSuccess() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateSuccessTime")
        let settings = UpdateSettings(defaults: suite.defaults)
        settings.autoCheckEnabled = true
        var clock = now
        var fails = true
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { clock }, fetcher: {
            if fails { throw URLError(.notConnectedToInternet) }
            return VersionChecker.Result(currentVersion: "1", latestVersion: "2", isUpToDate: false, releaseURL: nil)
        })
        await coordinator.performAutomaticCheck(force: true)
        XCTAssertEqual(settings.lastCheckAttempt, clock)
        XCTAssertNil(settings.lastSuccessfulCheck)
        XCTAssertNil(coordinator.lastSuccessfulCheck)
        clock = now.addingTimeInterval(86400)
        fails = false
        await coordinator.performAutomaticCheck(force: true)
        let success = clock
        XCTAssertEqual(settings.lastSuccessfulCheck, success)
        clock = now.addingTimeInterval(172800)
        fails = true
        await coordinator.performAutomaticCheck(force: true)
        XCTAssertEqual(settings.lastCheckAttempt, clock)
        XCTAssertEqual(settings.lastSuccessfulCheck, success)
        XCTAssertEqual(coordinator.lastSuccessfulCheck, success)
        XCTAssertEqual(UpdateSettings(defaults: suite.defaults).lastSuccessfulCheck, success)
    }


    private func waitForDelays(_ delay: PendingUpdateDelay, _ count: Int) async throws {
        for _ in 0..<1000 {
            if delay.durations.count >= count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) injected delays")
        throw CancellationError()
    }

    func testWakeWaitsSixtySecondsAndOffCancelsDelayedEvaluation() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateWake")
        let settings = UpdateSettings(defaults: suite.defaults)
        settings.autoCheckEnabled = true
        settings.lastCheckAttempt = now.addingTimeInterval(-86400)
        let probe = PendingUpdateFetch()
        let delay = PendingUpdateDelay()
        var clock = now
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { clock },
            fetcher: { try await probe.fetch() }, schedulingAllowed: { true }, delay: { try await delay.wait($0) })
        defer { coordinator.setAutoCheckEnabled(false); probe.finishAll(); delay.finishAll() }
        coordinator.startAfterOnboarding()
        try await waitForDelays(delay, 1) // Launch delay remains suspended.
        coordinator.handleWake()
        let wake = try XCTUnwrap(coordinator.wakeTaskForTesting)
        try await waitForDelays(delay, 2)
        XCTAssertEqual(delay.durations, [60, 60])
        coordinator.evaluateAutomaticCheck() // An overdue hourly timer must wait too.
        await coordinator.performAutomaticCheck() // A resumed launch delay must wait too.
        XCTAssertEqual(probe.calls, 0)
        XCTAssertEqual(settings.lastCheckAttempt, now.addingTimeInterval(-86400))
        delay.resume(1)
        await wake.value
        try await waitForCalls(probe, 1)
        let fetch = try XCTUnwrap(coordinator.automaticTaskForTesting)
        XCTAssertEqual(settings.lastCheckAttempt, now)
        probe.complete(0)
        await fetch.value
        clock = now.addingTimeInterval(90000)
        coordinator.handleWake()
        let cancelledWake = try XCTUnwrap(coordinator.wakeTaskForTesting)
        try await waitForDelays(delay, 3)
        coordinator.setAutoCheckEnabled(false)
        XCTAssertTrue(cancelledWake.isCancelled)
        delay.resume(2)
        await cancelledWake.value
        coordinator.evaluateAutomaticCheck()
        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(settings.lastCheckAttempt, now)
    }

    func testManualClickAttachesToAutomaticFetchAndShowsItsResultOnce() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateManualAttach")
        let settings = UpdateSettings(defaults: suite.defaults)
        let probe = PendingUpdateFetch()
        var shown: [String] = []
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { self.now },
            fetcher: { try await probe.fetch() }, schedulingAllowed: { true },
            manualConsent: { XCTFail("Automatic opt-in already provides consent"); return false },
            manualOutcome: { outcome in
                if case .success(let result) = outcome { shown.append(result.latestVersion) }
                else { XCTFail("Unexpected error") }
            })
        defer { coordinator.setAutoCheckEnabled(false); probe.finishAll() }
        coordinator.startAfterOnboarding()
        coordinator.setAutoCheckEnabled(true)
        let automatic = try XCTUnwrap(coordinator.automaticTaskForTesting)
        try await waitForCalls(probe, 1)
        coordinator.checkForUpdates()
        let manual = try XCTUnwrap(coordinator.manualTaskForTesting)
        coordinator.checkForUpdates() // A repeated click joins the same pending result.
        XCTAssertEqual(probe.calls, 1)
        probe.complete(0, version: "3")
        await automatic.value
        await manual.value
        XCTAssertEqual(shown, ["3"])
        XCTAssertEqual(coordinator.availableVersion, "3")
        XCTAssertFalse(coordinator.isCheckingForTesting)
        XCTAssertEqual(probe.calls, 1)
    }

    func testAttachedManualErrorSurvivesTurningDailyChecksOff() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateManualAttachOff")
        let settings = UpdateSettings(defaults: suite.defaults)
        let probe = PendingUpdateFetch()
        var errors = 0
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { self.now },
            fetcher: { try await probe.fetch() }, schedulingAllowed: { true }, manualOutcome: { outcome in
                if case .failure = outcome { errors += 1 } else { XCTFail("Expected offline error") }
            })
        defer { coordinator.setAutoCheckEnabled(false); probe.finishAll() }
        coordinator.startAfterOnboarding()
        coordinator.setAutoCheckEnabled(true)
        let automatic = try XCTUnwrap(coordinator.automaticTaskForTesting)
        try await waitForCalls(probe, 1)
        coordinator.checkForUpdates()
        let manual = try XCTUnwrap(coordinator.manualTaskForTesting)
        coordinator.setAutoCheckEnabled(false)
        XCTAssertTrue(automatic.isCancelled)
        XCTAssertFalse(manual.isCancelled)
        XCTAssertTrue(coordinator.isCheckingForTesting)
        XCTAssertFalse(coordinator.hasScheduleForTesting)
        probe.fail(0)
        await automatic.value
        await manual.value
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(probe.calls, 1)
        XCTAssertNil(settings.lastSuccessfulCheck)
        XCTAssertFalse(coordinator.isCheckingForTesting)
    }

    func testStandaloneManualSuccessAndErrorSurviveScheduleCancellation() async throws {
        for fails in [false, true] {
            let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateManualIndependent")
            let settings = UpdateSettings(defaults: suite.defaults)
            settings.autoCheckEnabled = true
            let probe = PendingUpdateFetch()
            var shown = 0
            let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { self.now },
                fetcher: { try await probe.fetch() }, schedulingAllowed: { true }, manualOutcome: { outcome in
                    shown += 1
                    switch outcome {
                    case .success(let result): XCTAssertFalse(fails); XCTAssertEqual(result.latestVersion, "4")
                    case .failure: XCTAssertTrue(fails)
                    }
                })
            defer { coordinator.setAutoCheckEnabled(false); probe.finishAll() }
            coordinator.startAfterOnboarding()
            coordinator.checkForUpdates()
            let manual = try XCTUnwrap(coordinator.manualTaskForTesting)
            try await waitForCalls(probe, 1)
            coordinator.setAutoCheckEnabled(false)
            XCTAssertFalse(manual.isCancelled)
            XCTAssertTrue(coordinator.isCheckingForTesting)
            if fails { probe.fail(0) } else { probe.complete(0, version: "4") }
            await manual.value
            XCTAssertEqual(shown, 1)
            XCTAssertEqual(probe.calls, 1)
            XCTAssertFalse(coordinator.isCheckingForTesting)
            XCTAssertEqual(coordinator.availableVersion, fails ? nil : "4")
        }
    }

    func testManualCheckWhenDisabledStillRequiresConsent() async throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateManualConsent")
        let settings = UpdateSettings(defaults: suite.defaults)
        let probe = PendingUpdateFetch()
        var accepted = false, consents = 0, shown = 0
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", now: { self.now },
            fetcher: { try await probe.fetch() }, manualConsent: { consents += 1; return accepted },
            manualOutcome: { _ in shown += 1 })
        defer { probe.finishAll() }
        coordinator.checkForUpdates()
        XCTAssertEqual(probe.calls, 0)
        XCTAssertNil(settings.lastCheckAttempt)
        accepted = true
        coordinator.checkForUpdates()
        let manual = try XCTUnwrap(coordinator.manualTaskForTesting)
        try await waitForCalls(probe, 1)
        probe.complete(0)
        await manual.value
        XCTAssertEqual(consents, 2)
        XCTAssertEqual(shown, 1)
    }

    func testUpdateItemIsRootOnlyAndSeparatesItselfAboveAbout() throws {
        let suite = try makeTestDefaultsSuite(prefix: "DailyUpdateRootMenu")
        let settings = UpdateSettings(defaults: suite.defaults)
        settings.latestVersion = "2"
        let coordinator = UpdateCheckCoordinator(settings: settings, currentVersion: "1", fetcher: { XCTFail("No network"); throw CancellationError() })
        let root = NSMenu()
        root.addItem(NSMenuItem(title: "Settings", action: nil, keyEquivalent: ""))
        root.addItem(.separator())
        let about = NSMenuItem(title: "About", action: nil, keyEquivalent: "")
        about.identifier = UpdateCheckCoordinator.aboutMenuIdentifier
        root.addItem(about)
        root.addItem(NSMenuItem(title: "Quit", action: nil, keyEquivalent: ""))
        for name in ["Dictation Mode", "Local", "Cloud"] {
            let submenu = NSMenu(title: name)
            submenu.addItem(NSMenuItem(title: "First", action: nil, keyEquivalent: ""))
            submenu.addItem(NSMenuItem(title: "Second", action: nil, keyEquivalent: ""))
            StatusBarController.refreshUpdateItem(in: submenu, rootMenu: root, coordinator: coordinator)
            XCTAssertEqual(submenu.numberOfItems, 2)
            XCTAssertFalse(submenu.items.contains { $0.identifier?.rawValue == "daily-update-available" })
        }
        for _ in 0..<2 { StatusBarController.refreshUpdateItem(in: root, rootMenu: root, coordinator: coordinator) }
        let update = try XCTUnwrap(root.items.firstIndex { $0.identifier?.rawValue == "daily-update-available" })
        XCTAssertEqual(root.index(of: about), update + 2)
        XCTAssertTrue(root.items[update - 1].isSeparatorItem)
        XCTAssertTrue(root.items[update + 1].isSeparatorItem)
        XCTAssertEqual(root.items.filter { $0.identifier?.rawValue == "daily-update-available" }.count, 1)
        XCTAssertEqual(root.items.filter { $0.identifier?.rawValue == "daily-update-separator" }.count, 1)
    }

}
