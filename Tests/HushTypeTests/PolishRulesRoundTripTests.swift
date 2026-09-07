import Foundation
import XCTest
@testable import HushType

@MainActor
final class PolishRulesRoundTripTests: XCTestCase {
    func testCompletePromptRoundTripPreservesHeadingsNewlinesAndBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("polish-prompt-roundtrip-\(UUID().uuidString)")
        AppSupportPaths.resetForTesting()
        AppSupportPaths.configure(root: root)
        defer {
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        let original = "# Complete Polish Prompt\n\n## Rules\nPreserve headings.\n\nKeep the final newline.\n"
        try PolishPrompt.saveCompletePrompt(original)

        XCTAssertEqual(PolishPrompt.effectivePromptSnapshot(), original)
        XCTAssertEqual(try Data(contentsOf: PolishPrompt.customPromptURL), Data(original.utf8))
    }
}
