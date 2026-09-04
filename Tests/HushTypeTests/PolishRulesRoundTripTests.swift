import Foundation
import XCTest
@testable import HushType

@MainActor
final class PolishRulesRoundTripTests: XCTestCase {
    func testRawEditorRoundTripPreservesCommentsAndBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("polish-rules-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("polish_rules.txt")
        let original = "# template comment\n# another comment\nNever add a final period.\n"

        try PolishPrompt.saveRulesVerbatim(original, at: url)
        let loaded = PolishPrompt.rawRulesContents(at: url)
        try PolishPrompt.saveRulesVerbatim(loaded, at: url)

        XCTAssertEqual(loaded, original)
        XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8))
    }

    func testShippingRulesPathCreatesDirectoryAndPreservesBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("polish-rules-shipping-path-\(UUID().uuidString)")
        AppSupportPaths.resetForTesting()
        AppSupportPaths.configure(root: root)
        defer {
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        let original = "# template comment\nNever add a final period.\n"
        try PolishPrompt.saveRulesVerbatim(original)

        XCTAssertEqual(
            PolishPrompt.rulesFileURL,
            root.appendingPathComponent("polish_rules.txt")
        )
        XCTAssertEqual(PolishPrompt.rawRulesContents(), original)
        XCTAssertEqual(try Data(contentsOf: PolishPrompt.rulesFileURL), Data(original.utf8))
    }
}
