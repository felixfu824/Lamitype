import XCTest
@testable import HushType

final class TranslationManagerTests: XCTestCase {
    @MainActor
    func testTranslationCardRelinquishesItsPanelSynchronouslyForSelectionCopy() throws {
        let card = TranslationCardWindow()
        card.show(sourceLanguage: "English", sourceText: "Sample", translatedText: "範例")
        let panel = try XCTUnwrap(card.panelForTesting)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey, "The displayed card supports its own keyboard interaction")
        XCTAssertTrue(card.dismiss(animated: false))
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.contentView)
        XCTAssertNil(card.panelForTesting)
        XCTAssertFalse(card.dismiss(animated: false), "A copy with no visible card needs no focus delay")
    }

    func testExplicitTargetOverridesAutomaticDirection() {
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "en",
                preferredTargetIdentifier: "ja"
            ),
            "ja"
        )
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "zh-Hant",
                preferredTargetIdentifier: "fr"
            ),
            "fr"
        )
    }

    func testAutoTargetPreservesChineseToEnglishDirection() {
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "zh-Hans",
                preferredTargetIdentifier: nil
            ),
            "en"
        )
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "zh-Hant",
                preferredTargetIdentifier: nil
            ),
            "en"
        )
    }

    func testAutoTargetPreservesNonChineseToTraditionalChineseDirection() {
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "en",
                preferredTargetIdentifier: nil
            ),
            "zh-Hant-TW"
        )
        XCTAssertEqual(
            TranslationManager.resolveTargetIdentifier(
                sourceIdentifier: "ja",
                preferredTargetIdentifier: nil
            ),
            "zh-Hant-TW"
        )
    }
}
