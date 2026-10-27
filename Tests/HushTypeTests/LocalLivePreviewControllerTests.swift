import AppKit
import XCTest
@testable import HushType

@MainActor
final class LocalLivePreviewControllerTests: XCTestCase {
    private final class State {
        var enabled = false, acknowledgement = 0, idle = true, local = true, work = false, modalFree = true
        var failWrite = false, explicitChoice = true
        var writes: [Bool] = [], acknowledgements: [Int] = []
        var queued: [() -> Void] = []
        var replies: [(LocalLivePreviewController.Choice) -> Void] = []
        var presentations = 0, refreshes = 0
    }
    private func make(_ state: State) -> LocalLivePreviewController {
        LocalLivePreviewController(
            activityIsIdle: { state.idle }, isLocal: { state.local }, hasOwnershipWork: { state.work },
            readEnabled: { state.enabled }, writeEnabled: { state.writes.append($0); if !state.failWrite { state.enabled = $0; state.explicitChoice = true } },
            hasExplicitChoice: { state.explicitChoice },
            readAcknowledgement: { state.acknowledgement }, writeAcknowledgement: { state.acknowledgement = $0; state.acknowledgements.append($0) },
            presenter: { _, done in state.presentations += 1; state.replies.append(done) },
            schedule: { state.queued.append($0) }, presentationAllowed: { _ in state.modalFree }, refresh: { state.refreshes += 1 })
    }
    private func drain(_ state: State) { while !state.queued.isEmpty { state.queued.removeFirst()() } }
    private func answer(_ state: State, enable: Bool, remember: Bool) {
        state.replies.removeFirst()(.init(enable: enable, dontShowAgain: remember)); drain(state)
    }

    func testEnableWithoutSuppressionRequiresConfirmationEveryEnable() {
        let s = State(), c = make(s)
        c.request(true, from: .menu)
        XCTAssertFalse(s.enabled); XCTAssertTrue(c.isRequestPending); XCTAssertTrue(s.writes.isEmpty)
        drain(s); XCTAssertEqual(s.presentations, 1)
        answer(s, enable: true, remember: false)
        XCTAssertTrue(s.enabled); XCTAssertEqual(s.acknowledgement, 0); XCTAssertFalse(c.isRequestPending)
        c.request(false, from: .menu); XCTAssertFalse(s.enabled)
        c.request(true, from: .menu); drain(s); XCTAssertEqual(s.presentations, 2)
    }
    func testCheckedCancelDoesNotPersistAndRefreshesControls() {
        let s = State(), c = make(s)
        c.request(true, from: .menu); drain(s)
        let refreshes = s.refreshes
        answer(s, enable: false, remember: true)
        XCTAssertFalse(s.enabled); XCTAssertEqual(s.acknowledgement, 0)
        XCTAssertTrue(s.writes.isEmpty); XCTAssertTrue(s.acknowledgements.isEmpty)
        XCTAssertGreaterThan(s.refreshes, refreshes); XCTAssertFalse(c.isRequestPending)
        c.request(true, from: .menu); drain(s); XCTAssertEqual(s.presentations, 2)
    }
    func testCheckedEnableSurvivesNewCoordinatorAndDisable() {
        let s = State(), c = make(s)
        c.request(true, from: .menu); drain(s); answer(s, enable: true, remember: true)
        XCTAssertEqual(s.acknowledgement, LocalLivePreviewController.reminderVersion)
        c.request(false, from: .menu)
        let next = make(s); next.request(true, from: .menu)
        XCTAssertTrue(s.enabled); XCTAssertEqual(s.presentations, 1); XCTAssertFalse(next.isRequestPending)
    }
    func testCloudBusyAndOwnershipChangesBeforePresentationRejectWithoutPopup() {
        for invalidate in [{ (s: State) in s.local = false }, { $0.idle = false }, { $0.work = true }, { $0.modalFree = false }] {
            let s = State(), c = make(s)
            c.request(true, from: .menu); invalidate(s); drain(s)
            XCTAssertEqual(s.presentations, 0); XCTAssertTrue(s.writes.isEmpty)
            XCTAssertFalse(c.isRequestPending); XCTAssertEqual(s.acknowledgement, 0)
        }
    }
    func testCommitRechecksAllAdmissionAndDoesNotSaveSuppression() {
        for invalidate in [{ (s: State) in s.local = false }, { $0.idle = false }, { $0.work = true }, { $0.modalFree = false }] {
            let s = State(), c = make(s)
            c.request(true, from: .menu); drain(s); invalidate(s)
            answer(s, enable: true, remember: true)
            XCTAssertFalse(s.enabled); XCTAssertTrue(s.writes.isEmpty); XCTAssertTrue(s.acknowledgements.isEmpty)
            XCTAssertFalse(c.isRequestPending)
        }
    }
    func testExternalPreferenceChangeSurvivesCancelOrConfirmation() {
        for enable in [false, true] {
            let s = State(), c = make(s)
            c.request(true, from: .menu); drain(s); s.enabled = true
            answer(s, enable: enable, remember: true)
            XCTAssertTrue(s.enabled); XCTAssertTrue(s.writes.isEmpty); XCTAssertTrue(s.acknowledgements.isEmpty)
        }
    }
    func testDuplicateRequestAndLateOldResponseCannotAffectNewRequest() {
        let s = State(), c = make(s)
        c.request(true, from: .menu); c.request(true, from: .menu); drain(s)
        XCTAssertEqual(s.presentations, 1)
        let oldReply = s.replies[0]
        answer(s, enable: false, remember: false)
        c.request(true, from: .menu); drain(s)
        oldReply(.init(enable: true, dontShowAgain: true)); drain(s)
        XCTAssertFalse(s.enabled); XCTAssertEqual(s.acknowledgement, 0); XCTAssertTrue(c.isRequestPending)
        answer(s, enable: true, remember: true)
        XCTAssertTrue(s.enabled); XCTAssertEqual(s.acknowledgement, 1)
    }
    func testMissingSettingsHostNeverFallsBackToAppModal() {
        let s = State(), c = make(s)
        c.request(true, from: .settings(nil)); drain(s)
        XCTAssertEqual(s.presentations, 0); XCTAssertFalse(c.isRequestPending); XCTAssertTrue(s.writes.isEmpty)
    }
    func testFailedEnableWriteDoesNotAcknowledge() {
        let s = State(), c = make(s); s.failWrite = true
        c.request(true, from: .menu); drain(s); answer(s, enable: true, remember: true)
        XCTAssertFalse(s.enabled); XCTAssertTrue(s.acknowledgements.isEmpty)
    }
    func testRefreshAndBusyAvailabilityDoNotWriteOrDisableWholePane() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cap-reminder-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AppSupportPaths.resetForTesting(); AppSupportPaths.configure(root: directory)
        defer { AppSupportPaths.resetForTesting(); try? FileManager.default.removeItem(at: directory) }
        let s = State(), c = make(s)
        let model = DictationSettingsModel(onSwitchEngine: { _ in }, previewController: c)
        model.refresh(); model.refreshLivePreview()
        XCTAssertTrue(s.writes.isEmpty); XCTAssertEqual(s.presentations, 0)
        s.idle = false; model.refreshLivePreview()
        XCTAssertFalse(model.livePreviewCanChange); XCTAssertFalse(model.liveBusy)
        s.idle = true
        model.requestLivePreviewEnabled(true, from: .menu); drain(s)
        XCTAssertEqual(s.presentations, 1); XCTAssertFalse(model.livePreviewEnabled)
        answer(s, enable: true, remember: false); model.refreshLivePreview()
        XCTAssertTrue(model.livePreviewEnabled)
    }
    func testMenuUsesSameExplicitCoordinator() {
        let s = State(), c = make(s)
        let text = TextSettingsModel(storage: .init(
            readPolishEnabled: { false }, writePolishEnabled: { _ in },
            readAutoPolishEnabled: { false }, writeAutoPolishEnabled: { _ in },
            readExcludedBundleIDs: { [] }, writeExcludedBundleIDs: { _ in },
            readTranslationEnabled: { false }, writeTranslationEnabled: { _ in },
            readTranslationTarget: { nil }, writeTranslationTarget: { _ in },
            readEvalCount: { 0 }, readEvalBytes: { 0 }, deleteAllEval: {}, revealEval: {}, showEvalWindow: { _ in }
        ), initialPolishAvailability: true, validatePolish: { .ok }, warmupPolish: {}, releasePolish: {}, presentUnavailable: { _ in })
        let bar = StatusBarController(localEngine: Qwen3TranscriptionEngine(), textSettingsModel: text, previewController: c)
        let item = bar.statusMenuForTesting.items.compactMap(\.submenu).flatMap(\.items).compactMap(\.submenu).flatMap(\.items).first { $0.action?.description == "selectLocalLive" }!
        XCTAssertTrue(NSApplication.shared.sendAction(item.action!, to: item.target, from: item))
        XCTAssertTrue(c.isRequestPending); XCTAssertFalse(s.enabled)
        drain(s); answer(s, enable: true, remember: true)
        XCTAssertTrue(s.enabled); XCTAssertEqual(s.acknowledgement, 1)
    }
    func testCloudToLocalLiveCancellationPreservesBothSelections() {
        let s = State(), c = make(s); s.local = false
        var switches = 0
        c.requestLocalMode(true) { switches += 1; s.local = true }
        drain(s)
        XCTAssertTrue(c.isRequestPending); XCTAssertFalse(s.local); XCTAssertFalse(s.enabled)
        answer(s, enable: false, remember: true)
        XCTAssertEqual(switches, 0); XCTAssertFalse(s.local); XCTAssertFalse(s.enabled)
        XCTAssertTrue(s.writes.isEmpty); XCTAssertTrue(s.acknowledgements.isEmpty)
        c.requestLocalMode(true) { switches += 1; s.local = true }
        drain(s); answer(s, enable: true, remember: false)
        XCTAssertEqual(switches, 1); XCTAssertTrue(s.local); XCTAssertTrue(s.enabled)
    }
    func testLocalModeSelectionRechecksBusyBeforeCommit() {
        let s = State(), c = make(s); s.local = false
        var switched = false
        c.requestLocalMode(true) { switched = true }; drain(s)
        s.work = true; answer(s, enable: true, remember: true)
        XCTAssertFalse(switched); XCTAssertFalse(s.enabled); XCTAssertEqual(s.acknowledgement, 0)
    }
    func testLocalStandardAndRetainedLiveChooseExplicitModes() {
        let s = State(), c = make(s); s.local = false; s.enabled = true
        var switched = 0
        c.requestLocalMode(true) { switched += 1 }
        XCTAssertEqual(switched, 1); XCTAssertEqual(s.presentations, 0); XCTAssertTrue(s.enabled)
        c.requestLocalMode(false) { switched += 1 }
        XCTAssertEqual(switched, 2); XCTAssertFalse(s.enabled); XCTAssertEqual(s.presentations, 0)
    }

    func testDefaultOnStillRequiresReminderBeforeExplicitChoice() {
        let s = State(), c = make(s); s.enabled = true; s.explicitChoice = false
        XCTAssertTrue(c.isEnabled); XCTAssertTrue(c.needsDefaultConfirmation)
        c.request(true, from: .menu); drain(s)
        XCTAssertEqual(s.presentations, 1); XCTAssertTrue(c.isRequestPending)
        answer(s, enable: false, remember: true)
        XCTAssertTrue(s.enabled); XCTAssertFalse(s.explicitChoice); XCTAssertTrue(c.needsDefaultConfirmation)
        XCTAssertTrue(s.writes.isEmpty); XCTAssertEqual(s.acknowledgement, 0)
        c.request(true, from: .menu); drain(s); answer(s, enable: true, remember: false)
        XCTAssertTrue(s.enabled); XCTAssertTrue(s.explicitChoice); XCTAssertFalse(c.needsDefaultConfirmation)
        XCTAssertEqual(s.acknowledgement, 0)
    }
    func testDefaultConfirmationDoesNotOverwriteNewExplicitStandardChoice() {
        let s = State(), c = make(s); s.enabled = true; s.explicitChoice = false
        c.request(true, from: .menu); drain(s)
        s.enabled = false; s.explicitChoice = true
        answer(s, enable: true, remember: true)
        XCTAssertFalse(s.enabled); XCTAssertTrue(s.writes.isEmpty); XCTAssertEqual(s.acknowledgement, 0)
    }
    func testDefaultWithRememberedReminderPersistsWithoutAnotherDialog() {
        let s = State(), c = make(s); s.enabled = true; s.explicitChoice = false; s.acknowledgement = 1
        c.request(true, from: .menu)
        XCTAssertTrue(s.enabled); XCTAssertTrue(s.explicitChoice)
        XCTAssertFalse(c.needsDefaultConfirmation); XCTAssertEqual(s.presentations, 0)
    }

    func testNativeAlertHasUncheckedCheckboxAndExplicitEnableCancel() {
        _ = NSApplication.shared
        let alert = LocalLiveCapReminderAlert.makeAlert()
        XCTAssertTrue(alert.showsSuppressionButton); XCTAssertEqual(alert.suppressionButton?.state, .off)
        XCTAssertEqual(alert.buttons.count, 2); XCTAssertEqual(alert.alertStyle, .informational)
        XCTAssertEqual(alert.window.identifier, LocalLiveCapReminderAlert.windowIdentifier)
        XCTAssertFalse(alert.informativeText.isEmpty)
    }
    func testSuppressionPersistsInDefaultsWithoutEnablingOnConstruction() {
        let suite = "LamitypeCapReminderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var done: ((LocalLivePreviewController.Choice) -> Void)?
        func controller(_ store: UserDefaults) -> LocalLivePreviewController {
            LocalLivePreviewController(activityIsIdle: { true }, isLocal: { true }, hasOwnershipWork: { false },
                readEnabled: { store.bool(forKey: "enabled") }, writeEnabled: { store.set($0, forKey: "enabled") }, hasExplicitChoice: { store.object(forKey: "enabled") != nil },
                readAcknowledgement: { store.integer(forKey: "ack") }, writeAcknowledgement: { store.set($0, forKey: "ack") },
                presenter: { _, callback in done = callback }, schedule: { $0() }, presentationAllowed: { _ in true }, refresh: {})
        }
        let first = controller(defaults)
        XCTAssertFalse(first.isEnabled); XCTAssertNil(done)
        first.request(true, from: .menu); done?(.init(enable: true, dontShowAgain: true))
        first.request(false, from: .menu); done = nil
        let reopened = controller(UserDefaults(suiteName: suite)!)
        XCTAssertFalse(reopened.isEnabled); reopened.request(true, from: .menu)
        XCTAssertTrue(reopened.isEnabled); XCTAssertNil(done)
    }
}
