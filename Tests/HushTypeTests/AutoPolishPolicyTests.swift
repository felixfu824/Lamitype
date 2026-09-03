import XCTest
@testable import HushType

final class AutoPolishPolicyTests: XCTestCase {
    private func decide(
        enabled: Bool = true,
        available: Bool = true,
        engine: AppConfig.DictationEngine = .local,
        target: String? = "com.example.editor",
        excluded: [String] = []
    ) -> AutoPolishPolicy.Decision {
        AutoPolishPolicy.decide(
            enabled: enabled,
            available: available,
            engine: engine,
            targetBundleID: target,
            excludedBundleIDs: excluded
        )
    }

    func testDecisionPrecedenceAndHappyPath() {
        XCTAssertEqual(decide(enabled: false, available: false, engine: .openai), .skip(.disabled))
        XCTAssertEqual(decide(available: false, engine: .gemini), .skip(.notLocalEngine))
        XCTAssertEqual(decide(available: false), .skip(.unavailable))
        XCTAssertEqual(decide(), .polish)
    }

    func testExcludedMatchIsNormalized() {
        XCTAssertEqual(
            decide(target: "com.Apple.Terminal ", excluded: [" com.apple.terminal"]),
            .skip(.excludedApp("com.apple.terminal"))
        )
    }

    func testUnknownTargetFailsClosed() {
        XCTAssertEqual(decide(target: nil), .skip(.unknownTarget))
        XCTAssertEqual(decide(target: "  "), .skip(.unknownTarget))
    }

    func testNormalizedUniqueDropsEmptyAndDuplicatesPreservingOrder() {
        XCTAssertEqual(
            AutoPolishPolicy.normalizedUnique([
                " Com.Example.One ", "", "com.example.two", "COM.EXAMPLE.ONE"
            ]),
            ["com.example.one", "com.example.two"]
        )
    }
}
