import AppKit
import XCTest
@testable import HushType

@MainActor
final class SettingsMenuStructureTests: XCTestCase {
    private actor ValidationGate {
        private var continuation: CheckedContinuation<TextPolisher.ValidationResult, Never>?

        func wait() async -> TextPolisher.ValidationResult {
            await withCheckedContinuation { continuation = $0 }
        }

        func finish(_ result: TextPolisher.ValidationResult) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    func testFinalMenuHasExactStructureAndSingleSettingsEntry() {
        let originalLanguage = AppConfig.shared.interfaceLanguageRaw
        defer {
            AppConfig.shared.interfaceLanguageRaw = originalLanguage
            L10n.resetLaunchStateForTests()
        }
        AppConfig.shared.interfaceLanguage = .english
        L10n.resetLaunchStateForTests()

        let model = makeTextModel()
        let controller = StatusBarController(
            localEngine: Qwen3TranscriptionEngine(),
            textSettingsModel: model
        )
        controller.statusMenuForTesting.update()
        let items = controller.statusMenuForTesting.items
        let ordinary = items.filter { !$0.isSeparatorItem }

        XCTAssertFalse(items[0].isEnabled, "native validation must preserve unrelated disabled rows")
        XCTAssertEqual(ordinary.count, 11)
        XCTAssertEqual(items.filter(\.isSeparatorItem).count, 4)
        XCTAssertEqual(
            items.enumerated().compactMap { $0.element.isSeparatorItem ? $0.offset : nil },
            [1, 8, 10, 12]
        )

        let settingsTitle = L10n.string("menu.settings", fallback: "Settings…")
        let settingsItems = ordinary.filter { $0.title == settingsTitle }
        XCTAssertEqual(settingsItems.count, 1)
        XCTAssertEqual(ordinary.firstIndex(of: settingsItems[0]), 7)
        XCTAssertEqual(items.firstIndex(of: settingsItems[0]), 9)
        XCTAssertEqual(settingsItems[0].keyEquivalent, ",")
        XCTAssertEqual(settingsItems[0].keyEquivalentModifierMask, [.command])

        let preservedSubmenuTitles = [
            L10n.string("menu.live_caption", fallback: "Live Caption"),
            L10n.string("menu.live_translated_caption", fallback: "Live Translated Caption"),
            L10n.string("menu.text_translation", fallback: "Text Translation"),
        ]
        for title in preservedSubmenuTitles {
            XCTAssertNotNil(ordinary.first(where: { $0.title == title })?.submenu)
        }

        let translationParent = ordinary.first {
            $0.title == L10n.string("menu.text_translation", fallback: "Text Translation")
        }!
        let translationMenu = translationParent.submenu!
        let enableItem = translationMenu.items.first {
            $0.title == L10n.string(
                "menu.text_translation.enable",
                fallback: "Enable Text Translation"
            )
        }!
        let targetItem = translationMenu.items.first {
            $0.title == L10n.string("menu.translate_to", fallback: "Translate to")
        }!
        let hintItem = translationMenu.items.last!
        XCTAssertEqual(translationParent.state, .off)
        XCTAssertEqual(enableItem.state, .off)
        XCTAssertTrue(targetItem.isHidden)
        XCTAssertTrue(hintItem.isHidden)

        model.setTranslationEnabled(true)
        model.setTranslationTarget("ja")

        XCTAssertEqual(translationParent.state, .on)
        XCTAssertEqual(enableItem.state, .on)
        XCTAssertFalse(targetItem.isHidden)
        XCTAssertFalse(hintItem.isHidden)
        XCTAssertEqual(
            targetItem.submenu?.items.first(where: {
                ($0.representedObject as? String) == "ja"
            })?.state,
            .on
        )

        let autoPolishItem = ordinary.first {
            $0.title == L10n.string(
                "menu.text_polish",
                fallback: "Auto Polish Dictation"
            )
        }
        XCTAssertNotNil(autoPolishItem)
        XCTAssertEqual(autoPolishItem?.state, .off)
        XCTAssertFalse(autoPolishItem?.isEnabled ?? true)
        XCTAssertNil(autoPolishItem?.toolTip)
        let masterOffRecoveryItem = recoveryItem(in: controller)
        XCTAssertEqual(
            masterOffRecoveryItem.title,
            L10n.string(
                "menu.text_polish.recovery.open_settings",
                fallback: "Enable Text Polish in Settings…"
            )
        )
        XCTAssertTrue(masterOffRecoveryItem.isEnabled)
        XCTAssertFalse(masterOffRecoveryItem.isHidden)
        XCTAssertEqual(masterOffRecoveryItem.action, NSSelectorFromString("openTextPolishSettings"))

        let enabledAutoController = StatusBarController(
            localEngine: Qwen3TranscriptionEngine(),
            textSettingsModel: makeTextModel(polishEnabled: true, autoPolishEnabled: true)
        )
        enabledAutoController.statusMenuForTesting.update()
        let enabledAutoItem = enabledAutoController.statusMenuForTesting.items.first {
            $0.title == L10n.string(
                "menu.text_polish",
                fallback: "Auto Polish Dictation"
            )
        }
        XCTAssertEqual(enabledAutoItem?.state, .on)
        XCTAssertTrue(enabledAutoItem?.isEnabled ?? false)
        XCTAssertNil(enabledAutoItem?.toolTip)
        XCTAssertTrue(recoveryItem(in: enabledAutoController).isHidden)

        XCTAssertFalse(ordinary.contains { $0.title == "Dictation Settings" })
        XCTAssertFalse(ordinary.contains { $0.title == "Interface Language" })
        XCTAssertFalse(ordinary.contains { $0.title == "Edit Polish Instructions" })
        XCTAssertFalse(ordinary.contains {
            $0.title.contains("iOS Server") || $0.title.contains("iOS 伺服器")
        })
    }

    func testAutoPolishVisibleStatusTracksUnavailableAndValidatingReasons() async {
        let unavailableModel = makeTextModel(
            polishEnabled: true,
            polishAvailable: false
        )
        let unavailableController = StatusBarController(
            localEngine: Qwen3TranscriptionEngine(),
            textSettingsModel: unavailableModel
        )
        unavailableController.statusMenuForTesting.update()
        let unavailableItem = autoPolishItem(in: unavailableController)
        XCTAssertFalse(unavailableItem.isEnabled)
        XCTAssertNil(unavailableItem.toolTip)
        let unavailableRecovery = recoveryItem(in: unavailableController)
        XCTAssertFalse(unavailableRecovery.isEnabled)
        XCTAssertFalse(unavailableRecovery.isHidden)
        XCTAssertEqual(
            unavailableRecovery.title,
            L10n.format(
                "menu.text_polish.status.unavailable",
                "Text Polish is unavailable: %1$@",
                arguments: [TextPolisher.unavailableReasonCached]
            )
        )

        let gate = ValidationGate()
        let validatingModel = makeTextModel(
            polishEnabled: true,
            validatePolish: { await gate.wait() }
        )
        let validatingController = StatusBarController(
            localEngine: Qwen3TranscriptionEngine(),
            textSettingsModel: validatingModel
        )
        let validation = Task { @MainActor in
            await validatingModel.setAutoPolishEnabled(true)
        }
        await Task.yield()
        validatingController.statusMenuForTesting.update()
        let validatingItem = autoPolishItem(in: validatingController)
        XCTAssertFalse(validatingItem.isEnabled)
        XCTAssertNil(validatingItem.toolTip)
        let validatingRecovery = recoveryItem(in: validatingController)
        XCTAssertFalse(validatingRecovery.isEnabled)
        XCTAssertFalse(validatingRecovery.isHidden)
        XCTAssertEqual(
            validatingRecovery.title,
            L10n.string(
                "menu.text_polish.status.validating",
                fallback: "Checking whether Text Polish is available…"
            )
        )

        await gate.finish(.ok)
        await validation.value
    }

    private func autoPolishItem(in controller: StatusBarController) -> NSMenuItem {
        controller.statusMenuForTesting.items.first {
            $0.title == L10n.string("menu.text_polish", fallback: "Auto Polish Dictation")
                || $0.title == L10n.string(
                    "menu.text_polish.validating",
                    fallback: "Auto Polish Dictation (validating…)"
                )
        }!
    }

    private func recoveryItem(in controller: StatusBarController) -> NSMenuItem {
        let items = controller.statusMenuForTesting.items
        let autoIndex = items.firstIndex(of: autoPolishItem(in: controller))!
        return items[autoIndex + 1]
    }

    private func makeTextModel(
        polishEnabled: Bool = false,
        autoPolishEnabled: Bool = false,
        polishAvailable: Bool = true,
        validatePolish: @escaping () async -> TextPolisher.ValidationResult = { .ok }
    ) -> TextSettingsModel {
        TextSettingsModel(
            storage: .init(
                readPolishEnabled: { polishEnabled },
                writePolishEnabled: { _ in },
                readAutoPolishEnabled: { autoPolishEnabled },
                writeAutoPolishEnabled: { _ in },
                readExcludedBundleIDs: { [] },
                writeExcludedBundleIDs: { _ in },
                readTranslationEnabled: { false },
                writeTranslationEnabled: { _ in },
                readTranslationTarget: { nil },
                writeTranslationTarget: { _ in },
                readEvalCount: { 0 },
                readEvalBytes: { 0 },
                deleteAllEval: {},
                revealEval: {},
                showEvalWindow: { _ in }
            ),
            initialPolishAvailability: polishAvailable,
            validatePolish: validatePolish,
            warmupPolish: {},
            releasePolish: {},
            presentUnavailable: { _ in }
        )
    }
}
