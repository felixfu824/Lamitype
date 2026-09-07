import XCTest
@testable import HushType

@MainActor
final class TextSettingsModelTests: XCTestCase {
    private actor ValidationGate {
        private var continuation: CheckedContinuation<TextPolisher.ValidationResult, Never>?

        func wait() async -> TextPolisher.ValidationResult {
            await withCheckedContinuation { continuation = $0 }
        }

        func succeed() {
            continuation?.resume(returning: .ok)
            continuation = nil
        }
    }

    private final class StateBox {
        var polish = false
        var autoPolish = false
        var excluded: [String] = []
        var translation = false
        var target: String?
        var warmups = 0
        var releases = 0
        var alerts: [String] = []
        var refreshes = 0
        var evalCount = 0
        var evalBytes: Int64 = 0
        var evalDeletes = 0
        var evalReveals = 0
        var evalShows = 0
        var evalPromptFocusRequests: [Bool] = []
    }

    func testPolishValidationPublishesValidatingThenEnablesAndWarmsUp() async {
        let box = StateBox()
        let model = makeModel(box: box, validation: .ok)
        var validatingStates: [Bool] = []
        model.onMenuRefresh = {
            box.refreshes += 1
            validatingStates.append(model.isValidatingPolish)
        }

        await model.setPolishEnabled(true)

        XCTAssertTrue(box.polish)
        XCTAssertTrue(model.polishEnabled)
        XCTAssertTrue(model.polishAvailable)
        XCTAssertEqual(box.warmups, 1)
        XCTAssertEqual(validatingStates, [true, false])
    }

    func testUnavailablePolishDoesNotEnableAndPresentsReason() async {
        let box = StateBox()
        let model = makeModel(
            box: box,
            validation: .unavailable(reason: "Apple Intelligence is off")
        )

        await model.setPolishEnabled(true)

        XCTAssertFalse(box.polish)
        XCTAssertFalse(model.polishEnabled)
        XCTAssertFalse(model.polishAvailable)
        XCTAssertEqual(box.warmups, 0)
        XCTAssertEqual(box.alerts, ["Apple Intelligence is off"])
    }

    func testDisablingPolishPersistsAndReleasesSession() async {
        let box = StateBox()
        box.polish = true
        let model = makeModel(box: box, validation: .ok)

        await model.setPolishEnabled(false)

        XCTAssertFalse(box.polish)
        XCTAssertFalse(model.polishEnabled)
        XCTAssertEqual(box.releases, 1)
        XCTAssertEqual(box.warmups, 0)
    }

    func testDisablingMasterClearsAutomaticAndEnablingReturnsToManual() async {
        let box = StateBox()
        box.polish = true
        box.autoPolish = true
        let model = makeModel(box: box, validation: .ok)

        await model.setPolishEnabled(false)
        XCTAssertFalse(box.polish)
        XCTAssertFalse(box.autoPolish)
        XCTAssertFalse(model.autoPolishEnabled)

        await model.setPolishEnabled(true)
        XCTAssertTrue(box.polish)
        XCTAssertFalse(box.autoPolish)
        XCTAssertFalse(model.autoPolishEnabled)
    }

    func testLegacyMasterOffAutomaticOnNormalizesToDisabled() {
        let box = StateBox()
        box.autoPolish = true

        let model = makeModel(box: box, validation: .ok)

        XCTAssertFalse(model.polishEnabled)
        XCTAssertFalse(model.autoPolishEnabled)
        XCTAssertFalse(box.autoPolish)
    }

    func testAutoPolishValidationEnablesAndWarmsUp() async {
        let box = StateBox()
        box.polish = true
        let model = makeModel(box: box, validation: .ok)

        await model.setAutoPolishEnabled(true)

        XCTAssertTrue(box.autoPolish)
        XCTAssertTrue(model.autoPolishEnabled)
        XCTAssertTrue(model.polishAvailable)
        XCTAssertEqual(box.warmups, 1)
    }

    func testUnavailableAutoPolishStaysOffAndPresentsReason() async {
        let box = StateBox()
        box.polish = true
        let model = makeModel(
            box: box,
            validation: .unavailable(reason: "Apple Intelligence is off")
        )

        await model.setAutoPolishEnabled(true)

        XCTAssertFalse(box.autoPolish)
        XCTAssertFalse(model.autoPolishEnabled)
        XCTAssertFalse(model.polishAvailable)
        XCTAssertEqual(box.alerts, ["Apple Intelligence is off"])
    }

    func testAutoPolishDisableKeepsSessionWhileMasterIsOn() async {
        let manualOn = StateBox()
        manualOn.polish = true
        manualOn.autoPolish = true
        let first = makeModel(box: manualOn, validation: .ok)
        await first.setAutoPolishEnabled(false)
        XCTAssertEqual(manualOn.releases, 0)
    }

    func testLateValidationCannotReEnableDisabledMaster() async {
        let box = StateBox()
        let gate = ValidationGate()
        let model = makeModel(box: box, validatePolish: { await gate.wait() })

        let enabling = Task { @MainActor in await model.setPolishEnabled(true) }
        await Task.yield()
        XCTAssertTrue(model.isValidatingPolish)

        await model.setPolishEnabled(false)
        await gate.succeed()
        await enabling.value

        XCTAssertFalse(box.polish)
        XCTAssertFalse(model.polishEnabled)
        XCTAssertFalse(model.isValidatingPolish)
        XCTAssertEqual(box.warmups, 0)
    }

    func testMenuRefreshDoesNotCancelPendingValidation() async {
        let box = StateBox()
        let gate = ValidationGate()
        let model = makeModel(box: box, validatePolish: { await gate.wait() })

        let enabling = Task { @MainActor in await model.setPolishEnabled(true) }
        await Task.yield()
        XCTAssertTrue(model.isValidatingPolish)

        model.refreshFromConfig(polishAvailability: true)
        XCTAssertTrue(model.isValidatingPolish)

        await gate.succeed()
        await enabling.value

        XCTAssertTrue(box.polish)
        XCTAssertTrue(model.polishEnabled)
        XCTAssertFalse(model.isValidatingPolish)
        XCTAssertEqual(box.warmups, 1)
    }

    func testLateAutoValidationCannotSurviveMasterDisable() async {
        let box = StateBox()
        box.polish = true
        let gate = ValidationGate()
        let model = makeModel(box: box, validatePolish: { await gate.wait() })

        let enabling = Task { @MainActor in await model.setAutoPolishEnabled(true) }
        await Task.yield()
        XCTAssertTrue(model.isValidatingPolish)

        await model.setPolishEnabled(false)
        await gate.succeed()
        await enabling.value

        XCTAssertFalse(box.polish)
        XCTAssertFalse(box.autoPolish)
        XCTAssertFalse(model.polishEnabled)
        XCTAssertFalse(model.autoPolishEnabled)
        XCTAssertFalse(model.isValidatingPolish)
        XCTAssertEqual(box.warmups, 0)
    }

    func testManualPolishDisableClearsAutoAndReleases() async {
        let box = StateBox()
        box.polish = true
        box.autoPolish = true
        let model = makeModel(box: box, validation: .ok)

        await model.setPolishEnabled(false)

        XCTAssertFalse(box.autoPolish)
        XCTAssertFalse(model.autoPolishEnabled)
        XCTAssertEqual(box.releases, 1)
    }

    func testExclusionsPersistNormalizedAndCanBeRemoved() {
        let box = StateBox()
        let model = makeModel(box: box, validation: .ok)

        model.setExcluded(" Com.Example.Editor ", excluded: true)
        model.setExcluded("COM.EXAMPLE.EDITOR", excluded: true)
        model.setExcluded("com.example.other", excluded: true)
        XCTAssertEqual(box.excluded, ["com.example.editor", "com.example.other"])
        XCTAssertEqual(model.excludedBundleIDs, box.excluded)

        model.removeExcluded(" COM.EXAMPLE.EDITOR ")
        XCTAssertEqual(box.excluded, ["com.example.other"])
    }

    func testTranslationEnableAndTargetPersistAndRefreshMenu() {
        let box = StateBox()
        let model = makeModel(box: box, validation: .ok)
        model.onMenuRefresh = { box.refreshes += 1 }

        model.setTranslationEnabled(true)
        model.setTranslationTarget("ja")

        XCTAssertTrue(box.translation)
        XCTAssertTrue(model.translationEnabled)
        XCTAssertEqual(box.target, "ja")
        XCTAssertEqual(model.translationTarget, "ja")
        XCTAssertEqual(box.refreshes, 2)
    }

    func testDeleteAllEvalInvokesClosureAndRefreshesCounts() {
        let box = StateBox()
        box.evalCount = 4
        box.evalBytes = 120
        let model = makeModel(box: box, validation: .ok)

        model.deleteAllEvalData()

        XCTAssertEqual(box.evalDeletes, 1)
        XCTAssertEqual(model.evalCount, 0)
        XCTAssertEqual(model.evalBytes, 0)
    }

    func testEditPolishInstructionsOpensUnifiedEvalWindow() {
        let box = StateBox()
        let model = makeModel(box: box)

        model.editPolishInstructions()

        XCTAssertEqual(box.evalShows, 1)
        XCTAssertEqual(box.evalPromptFocusRequests, [true])
    }

    func testShowEvalWindowDoesNotRequestPromptFocus() {
        let box = StateBox()
        let model = makeModel(box: box)

        model.showEvalWindow()

        XCTAssertEqual(box.evalShows, 1)
        XCTAssertEqual(box.evalPromptFocusRequests, [false])
    }

    func testPaneAndStatusBarHandlersUseSharedModelContract() throws {
        let pane = try source(named: "Settings/TextPane.swift")
        let statusBar = try source(named: "StatusBarController.swift")

        XCTAssertTrue(pane.contains("self.model = .shared"))
        XCTAssertTrue(pane.contains("model.requestPolishEnabled"))
        XCTAssertTrue(pane.contains("model.setTranslationEnabled"))
        XCTAssertTrue(pane.contains("model.setTranslationTarget"))
        XCTAssertFalse(pane.contains("AppConfig.shared.textPolishEnabled ="))
        XCTAssertFalse(pane.contains("AppConfig.shared.textTranslationEnabled ="))

        XCTAssertTrue(statusBar.contains("textSettingsModel.toggleAutoPolish()"))
        XCTAssertTrue(statusBar.contains("textSettingsModel.toggleTranslation()"))
        XCTAssertTrue(statusBar.contains("textSettingsModel.setTranslationTarget"))
        XCTAssertFalse(statusBar.contains("AppConfig.shared.textPolishEnabled ="))
        XCTAssertFalse(statusBar.contains("AppConfig.shared.textTranslationEnabled ="))
    }

    private func makeModel(
        box: StateBox,
        validation: TextPolisher.ValidationResult = .ok,
        validatePolish: (() async -> TextPolisher.ValidationResult)? = nil
    ) -> TextSettingsModel {
        TextSettingsModel(
            storage: .init(
                readPolishEnabled: { box.polish },
                writePolishEnabled: { box.polish = $0 },
                readAutoPolishEnabled: { box.autoPolish },
                writeAutoPolishEnabled: { box.autoPolish = $0 },
                readExcludedBundleIDs: { box.excluded },
                writeExcludedBundleIDs: { box.excluded = $0 },
                readTranslationEnabled: { box.translation },
                writeTranslationEnabled: { box.translation = $0 },
                readTranslationTarget: { box.target },
                writeTranslationTarget: { box.target = $0 },
                readEvalCount: { box.evalCount },
                readEvalBytes: { box.evalBytes },
                deleteAllEval: {
                    box.evalDeletes += 1
                    box.evalCount = 0
                    box.evalBytes = 0
                },
                revealEval: { box.evalReveals += 1 },
                showEvalWindow: {
                    box.evalShows += 1
                    box.evalPromptFocusRequests.append($0)
                }
            ),
            initialPolishAvailability: true,
            validatePolish: validatePolish ?? { validation },
            warmupPolish: { box.warmups += 1 },
            releasePolish: { box.releases += 1 },
            presentUnavailable: { box.alerts.append($0) }
        )
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HushType")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
