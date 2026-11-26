import XCTest
import AppKit
import SwiftUI
import Combine
@testable import HushType

/// Gate C Slice 2 — semantic menu behavior and lifecycle-safety checks.
@MainActor
final class LocalizationMenuTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        super.tearDown()
    }

    func testLanguageSelectionPersistsWithoutChangingLaunchLocale() {
        AppConfig.shared.interfaceLanguage = .english
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(L10n.launchTag, "en")
        let model = GeneralSettingsModel()

        model.selectInterfaceLanguage(.traditionalChineseTaiwan)

        XCTAssertEqual(model.selectedLanguage, .traditionalChineseTaiwan)
        XCTAssertEqual(AppConfig.shared.interfaceLanguage, .traditionalChineseTaiwan)
        XCTAssertEqual(L10n.launchTag, "en")
    }

    func testShortcutNamesAndGestureFormatInBothLocales() {
        for (locale, names, spoken) in [
            (InterfaceLanguage.english, ["Right ⌥", "Right ⌘", "Right ⌃"], ["Right Option", "Right Command", "Right Control"]),
            (.traditionalChineseTaiwan, ["右 ⌥", "右 ⌘", "右 ⌃"], ["右側 Option", "右側 Command", "右側 Control"]),
        ] {
            AppConfig.shared.interfaceLanguage = locale
            L10n.resetLaunchStateForTests()
            for (index, key) in DictationKey.allCases.enumerated() {
                XCTAssertEqual(ShortcutDisplay.dictation(key), names[index])
                XCTAssertEqual(ShortcutDisplay.dictation(key, spoken: true), spoken[index])
                let gestures = L10n.format("shortcut.gestures", "missing", arguments: [names[index]])
                XCTAssertTrue(gestures.contains(names[index])); XCTAssertFalse(gestures.contains("%1$@"))
            }
            XCTAssertEqual(ShortcutDisplay.caption(.rightCmdSlash), names[1] + " + /")
            XCTAssertEqual(ShortcutDisplay.caption(.controlOptionSlash), "⌃⌥ + /")
        }
    }

    func testSecureInputPauseNoticeNamesBoundCommandOrControlInBothLocales() {
        for language in [InterfaceLanguage.english, .traditionalChineseTaiwan] {
            AppConfig.shared.interfaceLanguage = language
            L10n.resetLaunchStateForTests()
            for key in [DictationKey.rightCommand, .rightControl] {
                let name = ShortcutDisplay.dictation(key)
                let message = L10n.format("shortcut.secure_input.paused", "missing", arguments: [name])
                let expected = language == .english
                    ? "Secure input is on, so \(name) dictation is paused. Leave the password field or turn off Secure Keyboard Entry."
                    : "安全輸入已開啟，\(name) 語音輸入暫停。離開密碼欄位或關閉「安全鍵盤輸入」後即可使用。"
                XCTAssertEqual(message, expected)
            }
        }
    }

    func testSecureInputNoticeWrapsAtHUDWidthInBothLocales() {
        _ = NSApplication.shared
        for locale in [InterfaceLanguage.english, .traditionalChineseTaiwan] {
            AppConfig.shared.interfaceLanguage = locale
            L10n.resetLaunchStateForTests()
            let message = L10n.format("shortcut.secure_input.paused", "missing",
                                      arguments: [ShortcutDisplay.dictation(.rightCommand)])
            let model = OverlayStateModel()
            model.state = .notice(message: message, style: .information(heading: ShortcutDisplay.dictation(.rightCommand)))
            let host = NSHostingView(rootView: FloatingOverlayView(model: model))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, FloatingOverlayGeometry.progressWidth, accuracy: 0.5)
            XCTAssertGreaterThan(host.fittingSize.height, FloatingOverlayGeometry.progressHeight)
            // Match the HUD's 36 pt padding, 14 pt icon and 12 pt spacing.
            let textHeight = (message as NSString).boundingRect(
                with: NSSize(width: 318, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 13)]).height
            XCTAssertGreaterThanOrEqual(host.fittingSize.height, textHeight + 24,
                "The complete localized remedy must fit without clipping")
        }
    }

    func testCaptionMoveNoteNamesBothShortcutsInBothLocales() {
        for (locale, expected) in [
            (InterfaceLanguage.english, "Live Caption moved to ⌃⌥ + / because Right ⌘ is now your dictation key."),
            (.traditionalChineseTaiwan, "即時字幕已改用 ⌃⌥ + /，因為右 ⌘ 現在是你的語音輸入鍵。"),
        ] {
            AppConfig.shared.interfaceLanguage = locale
            L10n.resetLaunchStateForTests()
            XCTAssertEqual(L10n.format(
                "shortcut.caption.moved", "missing",
                arguments: [ShortcutDisplay.caption(.controlOptionSlash), ShortcutDisplay.dictation(.rightCommand)]
            ), expected)
        }
    }

    func testShortcutSpacingAndTerminology() {
        AppConfig.shared.interfaceLanguage = .traditionalChineseTaiwan
        L10n.resetLaunchStateForTests()
        for key in ["menu.translation_hint", "alert.model_unloaded.local.message", "onboarding.intro",
                    "permission.accessibility.subtitle", "error.audio_capture.too_short",
                    "shortcut.binding.hint",
                    "shortcut.conflict.dictation", "shortcut.caption.moved"] {
            let template = L10n.string(key, fallback: "missing")
            XCTAssertNil(template.range(of: "%[12]\\$@\\p{Han}", options: .regularExpression), key)
        }
        XCTAssertEqual(L10n.format("menu.translation_hint", "missing", arguments: ["右 ⌥"]), "輕按右 ⌥ 以翻譯")
        XCTAssertEqual(L10n.format("permission.accessibility.subtitle", "missing", arguments: ["右側 Option"]), "右側 Option 快捷鍵需要這項權限。")
        for key in ["shortcut.mode.tap", "shortcut.mode.double", "shortcut.mode.hold"] {
            let text = L10n.string(key, fallback: "missing")
            for oldTerm in ["輕點", "雙擊", "點兩下", "點一下"] { XCTAssertFalse(text.contains(oldTerm), key) }
        }
        let secureInputNote = L10n.string("shortcut.recorder.footer", fallback: "missing")
        XCTAssertTrue(secureInputNote.contains("密碼欄位"))
    }

    func testDailyDisclosureIsConditionalAndLastCheckedRequiresSuccessInBothLocales() {
        for (locale, prefix, never) in [
            (InterfaceLanguage.english, "Lamitype checks GitHub now and daily.", "Not yet checked"),
            (.traditionalChineseTaiwan, "開啟後會立即向 GitHub 查詢", "尚未檢查"),
        ] {
            AppConfig.shared.interfaceLanguage = locale
            L10n.resetLaunchStateForTests()
            XCTAssertTrue(L10n.string("update.daily.disclosure", fallback: "missing").hasPrefix(prefix))
            XCTAssertEqual(AboutPane.lastCheckedText(lastSuccess: nil), never)
            let text = AboutPane.lastCheckedText(lastSuccess: Date(timeIntervalSince1970: 1_000_000))
            XCTAssertTrue(text.hasPrefix(locale == .english ? "Last checked: " : "上次檢查："))
            XCTAssertFalse(text.contains(never))
        }
    }

    func testAutomaticFailureDateAndControlPopupCopyInBothLocales() {
        for (locale, failurePrefix, controlPopup) in [
            (InterfaceLanguage.english, "Last attempt failed: ", "Right ⌃ (external keyboards)"),
            (.traditionalChineseTaiwan, "上次嘗試失敗：", "右 ⌃（外接鍵盤）"),
        ] {
            AppConfig.shared.interfaceLanguage = locale
            L10n.resetLaunchStateForTests()
            let text = AboutPane.failedAttemptText(Date(timeIntervalSince1970: 1_000_000))
            XCTAssertTrue(text.hasPrefix(failurePrefix))
            XCTAssertGreaterThan(text.count, failurePrefix.count)
            XCTAssertFalse(text.contains("%1$@"))
            XCTAssertEqual(ShortcutDisplay.dictationPopup(.rightControl), controlPopup)
            XCTAssertEqual(ShortcutDisplay.dictation(.rightControl), locale == .english ? "Right ⌃" : "右 ⌃")
            for key in [DictationKey.rightOption, .rightCommand] {
                XCTAssertEqual(ShortcutDisplay.dictationPopup(key), ShortcutDisplay.dictation(key))
            }
        }
    }

    func testDisabledPresetExplanationNamesPresetAndOwningKeyInBothLocales() throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.shortcut-disabled-note")
        defer { suite.destroy() }
        let model = ShortcutSettingsModel(config: AppConfig.forUpgradeTesting(defaults: suite.defaults))
        for locale in [InterfaceLanguage.english, .traditionalChineseTaiwan] {
            AppConfig.shared.interfaceLanguage = locale
            L10n.resetLaunchStateForTests()
            for key in DictationKey.allCases {
                model.select(dictation: key)
                guard key == .rightCommand else {
                    XCTAssertNil(model.unavailableCaptionShortcut)
                    continue
                }
                let disabled = try XCTUnwrap(model.unavailableCaptionShortcut)
                XCTAssertEqual(disabled, .rightCmdSlash)
                let message = L10n.format("shortcut.conflict.dictation", "missing",
                    arguments: [ShortcutDisplay.caption(disabled), ShortcutDisplay.dictation(key)])
                XCTAssertTrue(message.contains(ShortcutDisplay.caption(disabled)))
                XCTAssertTrue(message.contains(ShortcutDisplay.dictation(key)))
                XCTAssertFalse(message.contains("%"))
                if locale == .traditionalChineseTaiwan {
                    XCTAssertEqual(message, "右 ⌘ 是語音輸入鍵時，無法使用 右 ⌘ + /。")
                }
            }
        }
    }

    private func makeGestureTextModel(polishEnabled: Bool = false, translationEnabled: Bool = false) -> TextSettingsModel {
        let storage = TextSettingsModel.Storage(
            readPolishEnabled: { polishEnabled }, writePolishEnabled: { _ in },
            readAutoPolishEnabled: { false }, writeAutoPolishEnabled: { _ in },
            readExcludedBundleIDs: { [] }, writeExcludedBundleIDs: { _ in },
            readTranslationEnabled: { translationEnabled }, writeTranslationEnabled: { _ in },
            readTranslationTarget: { nil }, writeTranslationTarget: { _ in },
            readEvalCount: { 0 }, readEvalBytes: { 0 }, deleteAllEval: {}, revealEval: {}, showEvalWindow: { _ in })
        return TextSettingsModel(storage: storage, initialPolishAvailability: true,
            validatePolish: { .ok }, warmupPolish: {}, releasePolish: {}, presentUnavailable: { _ in XCTFail("Unexpected unavailable alert") })
    }

    func testActionHintsReflectIndependentBindingsAndClearedStateInBothLocales() throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.shortcut-gestures")
        defer { suite.destroy() }
        let shortcuts = ShortcutSettingsModel(config: AppConfig.forUpgradeTesting(defaults: suite.defaults))
        for (locale, chord, tap, doubleTap, off) in [
            (InterfaceLanguage.english, "Right ⌃", "Tap", "Double-tap", "Off: no shortcut."),
            (.traditionalChineseTaiwan, "右 ⌃", "輕按", "連按兩下", "已關閉"),
        ] {
            AppConfig.shared.interfaceLanguage = locale
            L10n.resetLaunchStateForTests()
            XCTAssertNil(shortcuts.assign(.init(chord: .rightControl, gesture: .tap), to: .translate))
            XCTAssertTrue(shortcuts.bindings[.translate].hint.contains(tap))
            XCTAssertTrue(shortcuts.bindings[.translate].hint.contains(chord))
            XCTAssertTrue(shortcuts.bindings[.polish].hint.contains(doubleTap))
            XCTAssertFalse(shortcuts.bindings[.polish].hint.contains(chord))
            shortcuts.clear(.translate)
            XCTAssertTrue(shortcuts.bindings[.translate].hint.contains(off))
            XCTAssertTrue(shortcuts.bindings[.polish].hint.contains(doubleTap))
        }
    }

    func testCaptionPresetNamesTheRequiredLeftModifierInBothLocales() {
        for (locale, option, control) in [
            (InterfaceLanguage.english, "⌃ + Left ⌥ + /", "Left ⌃ + ⌥ + /"),
            (.traditionalChineseTaiwan, "⌃ + 左 ⌥ + /", "左 ⌃ + ⌥ + /"),
        ] {
            AppConfig.shared.interfaceLanguage = locale
            L10n.resetLaunchStateForTests()
            XCTAssertEqual(ShortcutDisplay.caption(.controlOptionSlash, dictation: .rightOption), option)
            XCTAssertEqual(ShortcutDisplay.caption(.controlOptionSlash, dictation: .rightControl), control)
            XCTAssertEqual(ShortcutDisplay.caption(.controlOptionSlash, dictation: .rightCommand), "⌃⌥ + /")
        }
    }

    func testRestoreDefaultsMessageAndAvailabilityInBothLocales() throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.shortcut-restore")
        defer { suite.destroy() }
        let model = ShortcutSettingsModel(config: AppConfig.forUpgradeTesting(defaults: suite.defaults))
        XCTAssertFalse(model.canRestoreDefaults)
        model.restoreDefaults() // Must return without opening a modal.
        XCTAssertNil(suite.defaults.object(forKey: "hushtype.shortcut.bindings"))
        model.select(dictation: .rightCommand)
        XCTAssertTrue(model.canRestoreDefaults)
        for (locale, message) in [
            (InterfaceLanguage.english, "This restores the default key and gesture for every action."),
            (.traditionalChineseTaiwan, "所有動作的按鍵和手勢都會回復為預設值。"),
        ] {
            AppConfig.shared.interfaceLanguage = locale
            L10n.resetLaunchStateForTests()
            let alert = ShortcutSettingsModel.makeRestoreAlert()
            XCTAssertEqual(alert.informativeText, message)
            XCTAssertEqual(alert.buttons.first?.title, L10n.string("common.button.cancel", fallback: "missing"))
        }
    }

    func testShortcutControlsFitExistingPaneInBothLocales() throws {
        guard ProcessInfo.processInfo.environment["LAMITYPE_SHORTCUT_LAYOUT_QA"] == "1" else {
            throw XCTSkip("Set LAMITYPE_SHORTCUT_LAYOUT_QA=1 to render shortcut controls offscreen")
        }
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.shortcuts-layout-test")
        defer { suite.destroy() }
        let config = AppConfig.forUpgradeTesting(defaults: suite.defaults)
        for locale in [InterfaceLanguage.english, .traditionalChineseTaiwan] {
            AppConfig.shared.interfaceLanguage = locale
            L10n.resetLaunchStateForTests()
            for key in DictationKey.allCases {
                let caption: CaptionShortcut = key == .rightOption ? .rightCmdSlash : .controlOptionSlash
                config.shortcutBindings = .init(dictation: key, liveCaption: caption)
                let shortcuts = ShortcutSettingsModel(config: config)
                if key == .rightCommand {
                    shortcuts.clear(.dictate) // Include the persistent warning and row reset in layout QA.
                }
                let host = NSHostingView(rootView: GeneralPane(shortcuts: shortcuts, textSettings: makeGestureTextModel(polishEnabled: true)).background(Color(nsColor: .windowBackgroundColor)))
                let size = host.fittingSize
                XCTAssertEqual(size.width, SettingsPage<EmptyView>.width, accuracy: 1)
                XCTAssertEqual(size.height, GeneralPane.height, accuracy: 1)
                if ProcessInfo.processInfo.environment["LAMITYPE_SHORTCUT_LAYOUT_QA"] == "1" {
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: .aqua)
                    window.contentView = host
                    defer { window.contentView = nil }
                    host.frame = NSRect(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: "/tmp/lamitype-shortcuts-\(locale.rawValue)-\(key.rawValue).png"))
                }
            }
        }
    }

    func testCaptionRoleIsSemanticAndLocalized() {
        AppConfig.shared.interfaceLanguage = .english
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(CaptionLineRole.source.label, "SOURCE")
        XCTAssertEqual(CaptionLineRole.translated.accessibilityLabel, "Translated")

        AppConfig.shared.interfaceLanguage = .traditionalChineseTaiwan
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(CaptionLineRole.source.label, "原文")
        XCTAssertEqual(CaptionLineRole.translated.label, "翻譯")
        XCTAssertEqual(CaptionLineRole.source.accessibilityLabel, "原文語言")
    }

    func testModelMenuActionIsTyped() {
        let unload: StatusBarController.ModelMenuAction = .unload
        let reload: StatusBarController.ModelMenuAction = .reload
        XCTAssertNotEqual(unload, reload)
    }

    func testLanguageSelectionHandlerHasNoLifecycleAuthorityAndStrictNoOpGuard() throws {
        let body = try sourceSlice(
            from: "func selectInterfaceLanguage",
            until: "struct GeneralPane",
            in: "Settings/GeneralPane.swift"
        )
        XCTAssertTrue(body.contains("selected != AppConfig.shared.interfaceLanguage"))
        for forbidden in ["restart", "terminate", "NSApp", "AppDelegate", ".cancel", ".stop", "quitClicked"] {
            XCTAssertFalse(body.localizedCaseInsensitiveContains(forbidden), "Forbidden lifecycle call in language handler: \(forbidden)")
        }
    }

    func testModelActionHandlerDoesNotInspectRenderedTitle() throws {
        let body = try sourceSlice(
            from: "@objc private func unloadOrReloadModel",
            until: "func setModelUnloaded"
        )
        XCTAssertTrue(body.contains("switch modelMenuAction"))
        XCTAssertFalse(body.contains(".title"))
        XCTAssertFalse(body.contains("attributedTitle"))
        XCTAssertFalse(body.contains("contains("))
    }

    func testCaptionBehaviorDoesNotCompareRenderedSourceLabel() throws {
        let source = try String(contentsOf: sourceURL(named: "LiveCaptionView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("enum CaptionLineRole"))
        XCTAssertFalse(source.contains("roleLabel == \"SOURCE\""))
        XCTAssertFalse(source.contains("role.label =="))
    }

    func testCaptionPositionResetUsesCentralFrameStore() throws {
        let managerSource = try String(
            contentsOf: sourceURL(named: "LiveCaptionManager.swift"),
            encoding: .utf8
        )
        let windowSource = try String(
            contentsOf: sourceURL(named: "LiveCaptionWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(managerSource.contains("LiveCaptionPanelFrameStore.clear()"))
        XCTAssertFalse(managerSource.contains("hushtype.liveCaption.panelFrame"))
        XCTAssertTrue(windowSource.contains(
            "static let frameKey = \"hushtype.liveCaption.panelFrame.v3\""
        ))
    }

    private func sourceSlice(
        from startMarker: String,
        until endMarker: String,
        in file: String = "StatusBarController.swift"
    ) throws -> String {
        let source = try String(contentsOf: sourceURL(named: file), encoding: .utf8)
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound else {
            XCTFail("Could not locate source slice markers")
            return ""
        }
        return String(source[start..<end])
    }

    private func sourceURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HushType")
            .appendingPathComponent(name)
    }
}
