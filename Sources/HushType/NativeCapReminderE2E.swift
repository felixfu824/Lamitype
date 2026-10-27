#if DEBUG
import AppKit

/// Explicit opt-in UI test. Uses the real menu action, Settings AX checkbox,
/// native alert/sheet controls and global hotkey; never records audio.
@MainActor
final class NativeCapReminderE2E {
    private let root: URL
    private let menuToggle: () -> Bool
    private let menuAction: (String, String?) -> Bool
    private let inspect: () -> [String: Any]
    private var rows: [[String: Any]] = []
    private var unmet: [String] = []
    private var expectedDialog = false
    private var unexpectedDialogs = 0
    private let controller = LocalLivePreviewController.shared

    init(root: URL, menuToggle: @escaping () -> Bool, menuAction: @escaping (String, String?) -> Bool, inspect: @escaping () -> [String: Any]) {
        self.root = root; self.menuToggle = menuToggle; self.menuAction = menuAction; self.inspect = inspect
    }
    private func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func key(_ down: Bool) {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 61, keyDown: down)!
        event.type = .flagsChanged; event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40) : []
        event.post(tap: .cghidEventTap)
    }
    private func record(_ event: String, checks: [String: Bool] = [:], extra: [String: Any] = [:]) {
        var row = inspect()
        row["event"] = event; row["time"] = ISO8601DateFormatter().string(from: Date())
        row["interfaceLocale"] = L10n.launchTag
        for (name, value) in checks { row[name] = value; if !value { unmet.append(event + "." + name) } }
        for (name, value) in extra { row[name] = value }
        rows.append(row)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("reminder-e2e-results.json"), options: .atomic)
        }
    }
    private func settingsSelectedEngine() -> String? {
        func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
            return value
        }
        var seen = 0
        func find(_ node: AXUIElement, _ depth: Int) -> String? {
            guard depth < 22, seen < 2000 else { return nil }; seen += 1
            if attribute(node, kAXRoleAttribute) as? String == kAXRadioButtonRole,
               (attribute(node, kAXValueAttribute) as? NSNumber)?.intValue == 1 {
                let title = (attribute(node, kAXTitleAttribute) as? String ?? "") + (attribute(node, kAXDescriptionAttribute) as? String ?? "")
                if title.contains("OpenAI") { return "openai" }
                if title.contains("Gemini") { return "gemini" }
                if title.contains("Qwen3-ASR") { return "local" }
            }
            for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let value = find(child, depth + 1) { return value }
            }
            return nil
        }
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            if let value = find(window, 0) { return value }
        }
        return nil
    }

    private func settingsToggle() -> Bool {
        guard let host = LamitypeSettingsWindowController.shared.reminderParentWindow else { return false }
        func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
            return value
        }
        var seen = 0
        func find(_ node: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard depth < 20, seen < 1500 else { return nil }; seen += 1
            if attribute(node, kAXIdentifierAttribute) as? String == "local-live-preview-toggle" { return node }
            for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let found = find(child, depth + 1) { return found }
            }
            return nil
        }
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            guard attribute(window, kAXTitleAttribute) as? String == host.title else { continue }
            if let toggle = find(window, 0) { return AXUIElementPerformAction(toggle, kAXPressAction as CFString) == .success }
        }
        return false
    }

    private func dialog(_ event: String, checked: Bool, enable: Bool, settings: Bool = false,
                        heldHotkey: Bool = false, closeHost: Bool = false, firstRecord: Bool = false) async -> Bool {
        expectedDialog = true
        defer { expectedDialog = false }
        var found = false, initiallyUnchecked = false, correctHost = false, hotkeyBlocked = !heldHotkey
        var stage = 0
        var next = Date.distantPast
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let alert = LocalLiveCapReminderAlert.currentForNativeTesting else { return }
                if !found {
                    found = true
                    initiallyUnchecked = alert.showsSuppressionButton && alert.suppressionButton?.state == .off
                    correctHost = settings ? alert.window.sheetParent === LamitypeSettingsWindowController.shared.reminderParentWindow : alert.window.sheetParent == nil
                    if let view = alert.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: self.root.appendingPathComponent(event + ".png")) }
                    }
                    if firstRecord {
                        let state = self.inspect()
                        hotkeyBlocked = state["physicalKeyDown"] as? Bool == true && state["reminderIgnoredPress"] as? Bool == true
                            && state["captureFrames"] as? Int == 0 && state["appState"] as? String == "idle"
                    }
                    if checked { alert.suppressionButton?.performClick(nil) }
                    if heldHotkey { self.key(true); stage = 1; next = Date().addingTimeInterval(0.4); return }
                }
                if stage == 1 {
                    guard Date() >= next else { return }
                    let state = self.inspect()
                    hotkeyBlocked = state["physicalKeyDown"] as? Bool == true && state["reminderIgnoredPress"] as? Bool == true
                        && state["captureFrames"] as? Int == 0 && state["appState"] as? String == "idle"
                    self.key(false); stage = 2; next = Date().addingTimeInterval(0.15); return
                }
                if stage == 2, Date() < next { return }
                timer.invalidate()
                if closeHost { LamitypeSettingsWindowController.shared.reminderParentWindow?.close() }
                else { alert.buttons[enable ? 0 : 1].performClick(nil) }
            }
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate(); key(false) }
        let invoked: Bool
        if firstRecord { key(true); invoked = true } else { invoked = settings ? settingsToggle() : menuToggle() }
        for _ in 0..<160 {
            if found && !controller.isRequestPending { break }
            await wait(0.05)
        }
        let checks = ["actionInvoked": invoked, "nativeDialogShown": found, "initiallyUnchecked": initiallyUnchecked,
                      "correctSheetOrModal": correctHost, "hotkeyBlocked": hotkeyBlocked, "requestFinished": !controller.isRequestPending]
        record(event, checks: checks)
        if controller.isRequestPending { LocalLiveCapReminderAlert.currentForNativeTesting?.buttons.last?.performClick(nil); await wait(0.2) }
        return checks.values.allSatisfy { $0 }
    }

    func run() async {
        let defaults = UserDefaults.standard
        let keys = ["hushtype.localLivePreviewEnabled", "hushtype.localLiveCapReminderAcknowledgedVersion",
            "hushtype.textTranslationEnabled", "hushtype.textPolishEnabled", "hushtype.autoPolishDictationEnabled"]
        let originals = keys.map { defaults.object(forKey: $0) }
        let wasSettingsVisible = LamitypeSettingsWindowController.shared.reminderParentWindow?.isVisible == true
        defer {
            key(false)
            NativeLocalLiveCounters.gestureProbeOnly = false
            for (index, key) in keys.enumerated() {
                if let value = originals[index] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            if !wasSettingsVisible { LamitypeSettingsWindowController.shared.reminderParentWindow?.orderOut(nil) }
            NotificationCenter.default.post(name: .localLivePreviewControlsChanged, object: nil)
            record("preferences_restored")
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard AXIsProcessTrusted(), controller.canChange else { record("blocked", checks: ["ready": false]); return }
        let modalWatchdog = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.expectedDialog, let alert = LocalLiveCapReminderAlert.currentForNativeTesting else { return }
                self.unexpectedDialogs += 1
                alert.buttons.last?.performClick(nil)
            }
        }
        RunLoop.main.add(modalWatchdog, forMode: .common); RunLoop.main.add(modalWatchdog, forMode: .modalPanel)
        defer { modalWatchdog.invalidate() }
        defaults.removeObject(forKey: "hushtype.localLivePreviewEnabled")
        AppConfig.shared.localLiveCapReminderAcknowledgedVersion = 0
        // Exercise classification against our own empty field. Probe mode
        // intercepts service entry, so no private selection, clipboard or
        // translation-model download can be touched by these gesture checks.
        let gestureWindow = NSWindow(contentRect: NSRect(x: 200, y: 250, width: 360, height: 140), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        gestureWindow.isReleasedWhenClosed = false
        gestureWindow.title = "Lamitype first-use gesture QA"
        let field = NSTextView(frame: NSRect(x: 12, y: 12, width: 330, height: 100))
        gestureWindow.contentView?.addSubview(field)
        gestureWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); gestureWindow.makeFirstResponder(field)
        defer { gestureWindow.close() }
        NativeLocalLiveCounters.gestureProbeOnly = true
        AppConfig.shared.textTranslationEnabled = true; AppConfig.shared.textPolishEnabled = true
        await wait(0.4)
        let initialTranslations = NativeLocalLiveCounters.translationRoutes
        key(true); await wait(0.08); key(false); await wait(0.5)
        record("default_short_tap", checks: ["translationRouted": NativeLocalLiveCounters.translationRoutes == initialTranslations + 1,
            "noReminder": !controller.isRequestPending && LocalLiveCapReminderAlert.currentForNativeTesting == nil,
            "noCapture": inspect()["captureFrames"] as? Int == 0, "stillUnconfirmed": controller.needsDefaultConfirmation])
        if TextPolisher.isAvailableCached {
            let translations = NativeLocalLiveCounters.translationRoutes, polishes = NativeLocalLiveCounters.polishRoutes
            key(true); await wait(0.06); key(false); await wait(0.08)
            key(true); await wait(0.06); key(false); await wait(0.5)
            record("default_double_tap", checks: ["polishRouted": NativeLocalLiveCounters.polishRoutes == polishes + 1,
                "singleTapCancelled": NativeLocalLiveCounters.translationRoutes == translations,
                "noReminder": !controller.isRequestPending, "noCapture": inspect()["captureFrames"] as? Int == 0])
            let beforeSleep = NativeLocalLiveCounters.translationRoutes
            key(true); await wait(0.06); key(false); await wait(0.05)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            await wait(0.5)
            record("default_pending_tap_sleep", checks: ["translationCancelled": NativeLocalLiveCounters.translationRoutes == beforeSleep,
                "noReminder": !controller.isRequestPending, "noCapture": inspect()["captureFrames"] as? Int == 0])
        }
        // Simulate the session-only ownership flags of cloud MIC captions.
        // No caption backend is started and no audio/network request occurs.
        let originalMicOwnership = AppConfig.shared.liveCaptionUsesMicSource
        let originalCaptionEngine = AppConfig.shared.liveCaptionEngine
        defer { AppConfig.shared.liveCaptionUsesMicSource = originalMicOwnership; AppConfig.shared.liveCaptionEngine = originalCaptionEngine }
        AppConfig.shared.liveCaptionEngine = .cloudTranslate
        for beganDuringHold in [false, true] {
            let translations = NativeLocalLiveCounters.translationRoutes
            AppConfig.shared.liveCaptionUsesMicSource = !beganDuringHold
            key(true); await wait(0.06)
            AppConfig.shared.liveCaptionUsesMicSource = true
            await wait(0.35); key(false); await wait(0.2)
            record(beganDuringHold ? "default_cloud_mic_begins_during_hold" : "default_cloud_mic_caption_gate", checks: [
                "noReminder": !controller.isRequestPending && LocalLiveCapReminderAlert.currentForNativeTesting == nil,
                "noCapture": inspect()["captureFrames"] as? Int == 0,
                "noTranslation": NativeLocalLiveCounters.translationRoutes == translations,
                "stillUnconfirmed": controller.needsDefaultConfirmation])
            AppConfig.shared.liveCaptionUsesMicSource = false
        }
        AppConfig.shared.liveCaptionEngine = originalCaptionEngine
        // Real application-modal ownership, including a dialog arriving after
        // release while single-tap translation is still deferred.
        for timing in ["before_press", "during_press", "after_release"] {
            let translations = NativeLocalLiveCounters.translationRoutes
            let polishes = NativeLocalLiveCounters.polishRoutes
            if timing != "before_press" { key(true); await wait(0.05) }
            if timing == "after_release" { key(false); await wait(0.04) }
            let modal = NSWindow(contentRect: NSRect(x: 230, y: 280, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            modal.isReleasedWhenClosed = false
            modal.title = "Lamitype modal input QA"
            let began = ProcessInfo.processInfo.systemUptime
            var pressed = timing != "before_press", released = timing == "after_release"
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let elapsed = ProcessInfo.processInfo.systemUptime - began
                    if !pressed { self.key(true); pressed = true }
                    if !released && elapsed >= 0.07 { self.key(false); released = true }
                    if elapsed >= 0.55 { timer.invalidate(); NSApp.stopModal() }
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            modal.makeKeyAndOrderFront(nil); NSApp.runModal(for: modal)
            timer.invalidate(); key(false); modal.close(); await wait(0.5)
            record("default_modal_" + timing, checks: ["noTranslation": NativeLocalLiveCounters.translationRoutes == translations,
                "noPolish": NativeLocalLiveCounters.polishRoutes == polishes,
                "noReminder": !controller.isRequestPending, "noCapture": inspect()["captureFrames"] as? Int == 0])
        }
        gestureWindow.makeKeyAndOrderFront(nil); gestureWindow.makeFirstResponder(field)
        let shortcutTranslations = NativeLocalLiveCounters.translationRoutes
        let shortcutCalls = NativeLocalLiveCounters.captionShortcutRoutes
        key(true); await wait(0.06)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 44, keyDown: down)!
            event.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue | 0x10)
            event.post(tap: .cghidEventTap)
        }
        await wait(0.45); key(false); await wait(0.5)
        record("default_caption_shortcut_chord", checks: ["captionShortcutRoutedOnce": NativeLocalLiveCounters.captionShortcutRoutes == shortcutCalls + 1,
            "noTap": NativeLocalLiveCounters.translationRoutes == shortcutTranslations,
            "noReminder": !controller.isRequestPending, "noCapture": inspect()["captureFrames"] as? Int == 0])
        let beforeChord = NativeLocalLiveCounters.translationRoutes
        key(true); await wait(0.06)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 123, keyDown: down)!
            event.flags = .maskAlternate; event.post(tap: .cghidEventTap)
        }
        await wait(0.45); key(false); await wait(0.2)
        record("default_option_chord", checks: ["noTap": NativeLocalLiveCounters.translationRoutes == beforeChord,
            "noReminderAfterThreshold": !controller.isRequestPending && LocalLiveCapReminderAlert.currentForNativeTesting == nil,
            "noCapture": inspect()["captureFrames"] as? Int == 0, "emptyOwnedField": field.string.isEmpty])
        key(true); await wait(0.06)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await wait(0.4); key(false); await wait(0.2)
        record("default_pending_hold_sleep", checks: ["noStaleReminder": !controller.isRequestPending,
            "noCapture": inspect()["captureFrames"] as? Int == 0, "stillUnconfirmed": controller.needsDefaultConfirmation])
        let expectedTranslations = NativeLocalLiveCounters.translationRoutes
        let expectedPolishes = NativeLocalLiveCounters.polishRoutes
        record("default_on_before_first_use", checks: ["enabled": controller.isEnabled,
            "unconfirmed": controller.needsDefaultConfirmation, "noCapture": inspect()["captureFrames"] as? Int == 0])
        guard await dialog("default_first_press_cancel", checked: true, enable: false, firstRecord: true) else { return }
        await wait(0.2)
        record("default_cancel_state", checks: ["stillUnconfirmed": controller.needsDefaultConfirmation,
            "noStoredChoice": !AppConfig.shared.hasExplicitLocalLiveChoice,
            "noCapture": inspect()["captureFrames"] as? Int == 0,
            "noSuppression": AppConfig.shared.localLiveCapReminderAcknowledgedVersion == 0])
        guard await dialog("default_second_press_enable", checked: false, enable: true, firstRecord: true) else { return }
        await wait(0.2)
        record("default_enable_state", checks: ["enabled": controller.isEnabled,
            "confirmed": !controller.needsDefaultConfirmation, "storedChoice": AppConfig.shared.hasExplicitLocalLiveChoice,
            "noCaptureOnRelease": inspect()["captureFrames"] as? Int == 0,
            "pairedReleaseConsumed": inspect()["physicalKeyDown"] as? Bool == false && inspect()["reminderIgnoredPress"] as? Bool == false])
        AppConfig.shared.localLivePreviewEnabled = false
        record("start")
        let opened = menuAction("openSettings", nil); await wait(0.7)
        record("menu_settings_open", checks: ["actionInvoked": opened, "visible": LamitypeSettingsWindowController.shared.reminderParentWindow?.isVisible == true])
        LamitypeSettingsWindowController.shared.presentAndFocus(pane: .dictation); await wait(0.5)
        for provider in ["openai", "gemini"] {
            let sent = menuAction("selectCloudProvider:", provider); await wait(0.3)
            record("menu_cloud_" + provider, checks: ["actionInvoked": sent, "engineChanged": AppConfig.shared.dictationEngine.rawValue == provider,
                "settingsRadioMatches": settingsSelectedEngine() == provider])
        }
        let local = menuAction("selectLocalStandard", nil); await wait(0.4)
        record("menu_local_standard", checks: ["actionInvoked": local, "engineChanged": AppConfig.shared.dictationEngine == .local,
            "settingsRadioMatches": settingsSelectedEngine() == "local", "previewOff": !controller.isEnabled])
        LamitypeSettingsWindowController.shared.reminderParentWindow?.orderOut(nil)

        guard await dialog("menu_cancel_checked", checked: true, enable: false) else { return }
        record("cancel_state", checks: ["off": !controller.isEnabled, "notSuppressed": AppConfig.shared.localLiveCapReminderAcknowledgedVersion == 0])
        guard await dialog("menu_enable_unchecked", checked: false, enable: true) else { return }
        record("unchecked_enable_state", checks: ["enabled": controller.isEnabled, "notSuppressed": AppConfig.shared.localLiveCapReminderAcknowledgedVersion == 0])
        let disabled = menuToggle(); await wait(0.2)
        record("menu_disable", checks: ["actionInvoked": disabled, "off": !controller.isEnabled, "noDialog": LocalLiveCapReminderAlert.currentForNativeTesting == nil])
        LamitypeSettingsWindowController.shared.presentAndFocus(pane: .dictation)
        await wait(0.7)
        guard await dialog("settings_enable_checked_hotkey", checked: true, enable: true, settings: true, heldHotkey: true) else { return }
        record("checked_enable_state", checks: ["enabled": controller.isEnabled, "suppressed": AppConfig.shared.localLiveCapReminderAcknowledgedVersion == 1])
        let settingsDisabled = settingsToggle(); await wait(0.2)
        record("settings_disable", checks: ["actionInvoked": settingsDisabled, "off": !controller.isEnabled, "noDialog": LocalLiveCapReminderAlert.currentForNativeTesting == nil])
        let suppressedEnabled = menuToggle(); await wait(0.2)
        record("suppressed_cross_entry_enable", checks: ["actionInvoked": suppressedEnabled, "enabled": controller.isEnabled, "noDialog": LocalLiveCapReminderAlert.currentForNativeTesting == nil])
        _ = menuToggle(); await wait(0.2)
        AppConfig.shared.localLiveCapReminderAcknowledgedVersion = 0
        guard await dialog("settings_host_close", checked: true, enable: false, settings: true, closeHost: true) else { return }
        record("host_close_state", checks: ["off": !controller.isEnabled, "notSuppressed": AppConfig.shared.localLiveCapReminderAcknowledgedVersion == 0])
        record("reminder_releases_preserve_gestures", checks: ["noUnexpectedDialogs": unexpectedDialogs == 0, "noExtraTranslation": NativeLocalLiveCounters.translationRoutes == expectedTranslations,
            "noExtraPolish": NativeLocalLiveCounters.polishRoutes == expectedPolishes])
        record("finished", extra: ["automaticChecksPassed": unmet.isEmpty, "unmetChecks": unmet])
    }
}
#endif
