import Foundation
import XCTest
@testable import HushType

@MainActor
final class EvalRerunLiveTests: XCTestCase {
    func testRerunUsesInstructionsWithoutTouchingStandby() async throws {
        guard ProcessInfo.processInfo.environment["LAMITYPE_RUN_FM_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LAMITYPE_RUN_FM_INTEGRATION=1 to run Foundation Models integration")
        }
        let root = try configureIsolatedAppSupport()
        defer {
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        TextPolisher.refreshAvailabilityCache()
        guard TextPolisher.isAvailableCached else {
            throw XCTSkip(TextPolisher.unavailableReasonCached)
        }
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }

        FoundationModelsPolisher.warmup()
        let before = FoundationModelsPolisher.standbyFingerprintForTesting
        let result = await TextPolisher.rerun(
            "she go to school yesterday",
            instructions: PolishPrompt.systemPrompt + "\n\nNever add a final period.",
            budget: .polish
        )
        let after = FoundationModelsPolisher.standbyFingerprintForTesting

        guard case .success(let output, _) = result else {
            return XCTFail("Expected rerun success")
        }
        XCTAssertTrue(output.lowercased().contains("went"))
        XCTAssertEqual(before, after)
    }

    func testSavedCompletePromptIsHonoredByManualAutomaticAndDraftRerun() async throws {
        guard ProcessInfo.processInfo.environment["LAMITYPE_RUN_FM_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LAMITYPE_RUN_FM_INTEGRATION=1 to run Foundation Models integration")
        }
        let root = try configureIsolatedAppSupport()
        let previousMaster = AppConfig.shared.textPolishEnabled
        let previousAutomatic = AppConfig.shared.autoPolishDictationEnabled
        let previousExclusions = AppConfig.shared.autoPolishExcludedBundleIDs
        defer {
            if #available(macOS 26.0, *) { FoundationModelsPolisher.releaseSession() }
            AppConfig.shared.textPolishEnabled = previousMaster
            AppConfig.shared.autoPolishDictationEnabled = previousAutomatic
            AppConfig.shared.autoPolishExcludedBundleIDs = previousExclusions
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        TextPolisher.refreshAvailabilityCache()
        guard TextPolisher.isAvailableCached else {
            throw XCTSkip(TextPolisher.unavailableReasonCached)
        }
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }

        AppConfig.shared.textPolishEnabled = true
        AppConfig.shared.autoPolishDictationEnabled = true
        AppConfig.shared.autoPolishExcludedBundleIDs = []
        let savedPrompt = """
You are an exact text echo. Return the text inside <selection> tags byte for byte.
Do not fix spelling, grammar, capitalization, or punctuation. Output only the text itself.

Example:
Input: <selection>She dont write good.</selection>
Output: She dont write good.
"""
        try PolishPrompt.saveCompletePrompt(savedPrompt)
        FoundationModelsPolisher.warmup()

        let input = "She dont write good."
        assertUnchanged(await TextPolisher.polish(input), input: input, route: "manual")

        XCTAssertEqual(
            AutoPolishPolicy.decideNow(engine: .local, targetBundleID: "com.example.integration"),
            .polish
        )
        let automatic = await DictationPolishStage.apply(input) {
            await TextPolisher.polishDictation($0)
        }
        XCTAssertEqual(automatic.text, input)
        XCTAssertEqual(automatic.outcome, .polished(changed: false))

        let standbyBeforeDraft = FoundationModelsPolisher.standbyFingerprintForTesting
        let draftPrompt = savedPrompt + "\n# Unsaved Eval draft"
        assertUnchanged(
            await TextPolisher.rerun(input, instructions: draftPrompt, budget: .polish),
            input: input,
            route: "rerun"
        )
        XCTAssertEqual(
            FoundationModelsPolisher.standbyFingerprintForTesting,
            standbyBeforeDraft,
            "An unsaved Eval draft must not consume or replace the everyday standby"
        )
        XCTAssertEqual(PolishPrompt.effectivePromptSnapshot(), savedPrompt)
    }

    private func assertUnchanged(_ result: PolishResult, input: String, route: String) {
        guard case .success(let output, let changed) = result else {
            return XCTFail("Expected \(route) route to honor the exact-echo prompt, got \(result)")
        }
        XCTAssertEqual(output, input, "\(route) route did not honor the saved complete prompt")
        XCTAssertFalse(changed)
    }

    private func configureIsolatedAppSupport() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-rerun-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let roots = AppSupportMigrator.productionRoots(in: sandbox)
        let selected = try AppSupportMigrator.migrate(oldRoot: roots.old, newRoot: roots.new).get()
        AppSupportPaths.resetForTesting()
        AppSupportPaths.configure(root: selected)
        return sandbox
    }
}
