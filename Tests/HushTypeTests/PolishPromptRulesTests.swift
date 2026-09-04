import Foundation
import XCTest
@testable import HushType

@MainActor
final class PolishPromptRulesTests: XCTestCase {
    func testNilAndCommentOnlyRulesReturnSystemPrompt() {
        XCTAssertEqual(PolishPrompt.prompt(withRules: nil), PolishPrompt.systemPrompt)
        XCTAssertEqual(PolishPrompt.prompt(withRules: "# comment\n  # another"), PolishPrompt.systemPrompt)
    }

    func testRulesUseExistingCommentParserAndMergeBeforeExamples() {
        let rules = "# keep this hidden\nNever add a period.\n"
        let prompt = PolishPrompt.prompt(withRules: rules)
        XCTAssertTrue(prompt.contains("User preferences (apply in addition"))
        XCTAssertTrue(prompt.contains("Never add a period.\n\nExamples:"))
        XCTAssertFalse(prompt.contains("keep this hidden"))
        XCTAssertEqual(
            EvalWindowModel.persistedRerunInstructions(
                raw: rules,
                fullOverrideActive: false
            ),
            "Never add a period."
        )
        XCTAssertNil(EvalWindowModel.persistedRerunInstructions(
            raw: rules,
            fullOverrideActive: true
        ))
    }

    func testShippedMergeIsByteEqualAndFullOverrideWinsForRerun() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("polish-prompt-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppSupportPaths.resetForTesting()
        AppSupportPaths.configure(root: root)
        CleanupPromptOverride.resetForTesting()
        defer {
            CleanupPromptOverride.resetForTesting()
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        let rawRules = "# preserved editor comment\nNever add a final period.\n"
        try PolishPrompt.saveRulesVerbatim(rawRules)
        let merged = PolishPrompt.prompt(withRules: rawRules)
        let shipped = PolishPrompt.activePrompt()
        XCTAssertEqual(Data(shipped.utf8), Data(merged.utf8))

        let fullOverride = "Full prompt wins exactly."
        try fullOverride.write(
            to: AppConfig.promptOverrideURL(filename: "polish_prompt.txt"),
            atomically: true,
            encoding: .utf8
        )
        CleanupPromptOverride.resetForTesting()
        XCTAssertEqual(PolishPrompt.activePrompt(), fullOverride)
        XCTAssertEqual(
            PolishPrompt.rerunPrompt(withRules: "Editor text must be ignored."),
            fullOverride
        )
    }
}
