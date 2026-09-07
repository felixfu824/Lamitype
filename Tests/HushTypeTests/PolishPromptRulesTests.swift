import Foundation
import XCTest
@testable import HushType

@MainActor
final class PolishPromptRulesTests: XCTestCase {
    func testDefaultIsNotMaterializedAndFullPromptPreservesHeadings() throws {
        try withPromptRoot { root in
            XCTAssertEqual(PolishPrompt.effectivePromptSnapshot(), PolishPrompt.systemPrompt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: PolishPrompt.customPromptURL.path))
            let custom = "# Proofreading\n\nKeep #hashtags unchanged.\n"
            try PolishPrompt.saveCompletePrompt(custom)
            XCTAssertEqual(PolishPrompt.effectivePromptSnapshot(), custom)
            XCTAssertTrue(PolishPrompt.hasCustomization)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(PolishPrompt.migrationMarkerFilename).path))
        }
    }

    func testEmptySaveKeepsPriorEffectivePrompt() throws {
        try withPromptRoot { _ in
            let prior = "# Custom\nProofread mechanically."
            try PolishPrompt.saveCompletePrompt(prior)
            XCTAssertThrowsError(try PolishPrompt.saveCompletePrompt(" \n\t")) { error in
                XCTAssertEqual(error as? PolishPrompt.PromptSaveError, .empty)
            }
            XCTAssertEqual(PolishPrompt.effectivePromptSnapshot(), prior)
        }
    }

    func testLegacyFullOverrideWinsAndMigratesFormerEffectiveValue() throws {
        try withPromptRoot { root in
            let full = root.appendingPathComponent(PolishPrompt.legacyFullPromptFilename)
            let rules = root.appendingPathComponent(PolishPrompt.legacyRulesFilename)
            try "# old comment\nFull override wins.".write(to: full, atomically: true, encoding: .utf8)
            try "Never add a period.".write(to: rules, atomically: true, encoding: .utf8)
            XCTAssertEqual(PolishPrompt.effectivePromptSnapshot(), "Full override wins.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: full.appendingPathExtension("legacy-backup").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: rules.appendingPathExtension("legacy-backup").path))
        }
    }

    func testLegacyRulesMaterializePriorMergedPromptOnce() throws {
        try withPromptRoot { root in
            let rules = root.appendingPathComponent(PolishPrompt.legacyRulesFilename)
            try "# ignored\nNever add a period.".write(to: rules, atomically: true, encoding: .utf8)
            let expected = PolishPrompt.prompt(withRules: "# ignored\nNever add a period.")
            XCTAssertEqual(PolishPrompt.effectivePromptSnapshot(), expected)
            try "A stale edit must not reactivate.".write(to: rules, atomically: true, encoding: .utf8)
            XCTAssertEqual(PolishPrompt.effectivePromptSnapshot(), expected)
            try PolishPrompt.restoreDefaultPrompt()
            XCTAssertEqual(PolishPrompt.effectivePromptSnapshot(), PolishPrompt.systemPrompt)
            XCTAssertFalse(PolishPrompt.hasCustomization)
        }
    }

    func testPartialMigrationNeverOverwritesExistingCustomPrompt() throws {
        try withPromptRoot { root in
            let custom = root.appendingPathComponent(PolishPrompt.customPromptFilename)
            let legacy = root.appendingPathComponent(PolishPrompt.legacyFullPromptFilename)
            try "Already saved after an interrupted migration.".write(to: custom, atomically: true, encoding: .utf8)
            try "Stale legacy prompt.".write(to: legacy, atomically: true, encoding: .utf8)
            XCTAssertEqual(
                PolishPrompt.effectivePromptSnapshot(),
                "Already saved after an interrupted migration."
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: PolishPrompt.migrationMarkerURL.path))
        }
    }

    func testDraftResolverUsesCompletePromptVerbatim() throws {
        try withPromptRoot { _ in
            try PolishPrompt.saveCompletePrompt("Saved prompt")
            XCTAssertEqual(PolishPrompt.rerunPrompt(withRules: "# Draft\nKeep headings."), "# Draft\nKeep headings.")
            XCTAssertEqual(PolishPrompt.rerunPrompt(withRules: " \n"), " \n")
            XCTAssertEqual(PolishPrompt.rerunPrompt(withRules: nil), "Saved prompt")
        }
    }

    func testInterruptedMigrationServesCanonicalCustomButBlocksWrites() throws {
        try withPromptRoot { root in
            let custom = root.appendingPathComponent(PolishPrompt.customPromptFilename)
            let legacy = root.appendingPathComponent(PolishPrompt.legacyFullPromptFilename)
            try "Canonical custom survives.".write(to: custom, atomically: true, encoding: .utf8)
            try "Legacy must not win.".write(to: legacy, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: PolishPrompt.migrationMarkerURL,
                withIntermediateDirectories: false
            )

            XCTAssertEqual(PolishPrompt.effectivePromptSnapshot(), "Canonical custom survives.")
            XCTAssertThrowsError(try PolishPrompt.saveCompletePrompt("Replacement")) { error in
                XCTAssertEqual(error as? PolishPrompt.PromptSaveError, .migrationFailed)
            }
            XCTAssertEqual(try String(contentsOf: custom, encoding: .utf8), "Canonical custom survives.")
        }
    }

    private func withPromptRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unified-polish-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppSupportPaths.resetForTesting()
        AppSupportPaths.configure(root: root)
        CleanupPromptOverride.resetForTesting()
        defer {
            CleanupPromptOverride.resetForTesting()
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }
}
