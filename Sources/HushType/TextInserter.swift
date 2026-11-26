import AppKit

struct TextInserter {
    static func insert(_ text: String, stageLog: DictationStageLog? = nil) {
        _ = insertAttempt(text, stageLog: stageLog)
    }

    static func insertLive(
        _ text: String, targetPID: pid_t, stageLog: DictationStageLog? = nil, verify: () -> Bool
    ) -> Bool {
        livePasteDenial(text, targetPID: targetPID, stageLog: stageLog,
                        verify: { verify() ? nil : .targetUnverified }) == nil
    }

    /// Clipboard-only delivery. A copy made by the user during dictation wins.
    static func copyLiveFallback(_ text: String, initialChangeCount: Int,
                                 pasteboard: NSPasteboard = .general, isAllowed: () -> Bool) -> Bool {
        guard !text.isEmpty, isAllowed(), pasteboard.changeCount == initialChangeCount else { return false }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let owner = pasteboard.changeCount
        guard pasteboard.setString(text, forType: .string) else { return false }
        guard isAllowed() else {
            if pasteboard.changeCount == owner { pasteboard.clearContents() }
            return false
        }
        return pasteboard.changeCount == owner
    }

    static func livePasteDenial(
        _ text: String, targetPID: pid_t, stageLog: DictationStageLog? = nil,
        pasteboard: NSPasteboard = .general, verify: () -> LivePasteReason?
    ) -> LivePasteReason? {
        guard targetPID > 0 else { return .missingApplication }
        guard !text.isEmpty else { return .emptyText }
        if let reason = verify() { return reason }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return .eventCreation }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: ShortcutBindings.syntheticEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: ShortcutBindings.syntheticEventTag)
        let oldInput = InputSourceManager.isCJKInputSourceActive() ? InputSourceManager.switchToASCII() : nil
        defer { if let oldInput { InputSourceManager.restore(inputSourceID: oldInput) } }
        if oldInput != nil { usleep(100_000) }
        if let reason = verify() { return reason }
        let oldItems = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
                values[type] = item.data(forType: type)
            }
        } ?? []
        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        let writtenChangeCount = pasteboard.changeCount
        let editable = wrote && stageLog != nil && focusedElementIsEditable(in: targetPID)
        if let reason = wrote ? verify() : .clipboardWrite {
            // Abort without replacing a clipboard the user changed concurrently.
            if pasteboard.changeCount == writtenChangeCount {
                pasteboard.clearContents()
                pasteboard.writeObjects(oldItems.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
            }
            return reason
        }
        // Deliver only to the application whose original field still passes
        // verification. Global HID delivery can paste twice in Claude Desktop.
        // Never fall back to a global event or reactivate a changed target.
        down.postToPid(targetPID)
        usleep(50_000)
        up.postToPid(targetPID)
        stageLog?.emit(.pasteDispatched(text: text, focusedElementEditable: editable))
        usleep(500_000)
        return nil // Dispatch only; target acceptance is not observable.
    }

    private static func insertAttempt(
        _ text: String, stageLog: DictationStageLog?, verify: () -> Bool = { true }
    ) -> Bool {
        guard verify() else { return false }
        guard !text.isEmpty else {
            print("[TextInserter] Empty text, skipping")
            return false
        }

        let pasteboard = NSPasteboard.general

        // Set transcription text to clipboard. Intentionally NOT saving/restoring
        // the previous clipboard contents — leaving the result on the clipboard
        // lets the user re-paste elsewhere or recover if cursor paste was blocked
        // by the focused app.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Handle CJK input method
        var previousInputSourceID: String?
        if InputSourceManager.isCJKInputSourceActive() {
            previousInputSourceID = InputSourceManager.switchToASCII()
            print("[TextInserter] CJK IM detected, switched to ASCII")
            usleep(100_000) // 100ms
        }

        // Simulate Cmd+V
        let editable = stageLog != nil && NSWorkspace.shared.frontmostApplication.map {
            focusedElementIsEditable(in: $0.processIdentifier)
        } == true
        guard verify() else {
            if let previousInputSourceID { InputSourceManager.restore(inputSourceID: previousInputSourceID) }
            return false
        }
        let sent = simulatePaste()
        if sent {
            stageLog?.emit(.pasteDispatched(text: text, focusedElementEditable: editable))
        }
        print("[TextInserter] Cmd+V sent")

        // Wait longer for paste to complete
        usleep(500_000) // 500ms

        // Restore input source
        if let previousID = previousInputSourceID {
            InputSourceManager.restore(inputSourceID: previousID)
            print("[TextInserter] Restored input source")
        }

        print("[TextInserter] Insert complete")
        return sent
    }

    private static func focusedElementIsEditable(in pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(pid)
        // Bound diagnostic calls to an unresponsive target without changing the
        // default timeout for the rest of the app's Accessibility requests.
        let timeout: Float = 0.05
        guard AXUIElementSetMessagingTimeout(application, timeout) == .success,
              let element = LivePasteAXSnapshot.element(application, kAXFocusedUIElementAttribute),
              AXUIElementSetMessagingTimeout(element, timeout) == .success
        else { return false }

        var settable = DarwinBoolean(false)
        let selectionStatus = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        if selectionStatus == .success, settable.boolValue { return true }
        guard selectionStatus != .cannotComplete else { return false }
        // A settable value alone can also belong to controls such as sliders.
        switch LivePasteAXSnapshot.string(element, kAXRoleAttribute) {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole:
            return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
                && settable.boolValue
        default:
            return false
        }
    }

    private static func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        // kVK_ANSI_V = 0x09
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            print("[TextInserter] ERROR: Failed to create CGEvent")
            return false
        }

        keyDown.flags = .maskCommand
        keyDown.setIntegerValueField(.eventSourceUserData, value: ShortcutBindings.syntheticEventTag)
        keyUp.flags = .maskCommand
        keyUp.setIntegerValueField(.eventSourceUserData, value: ShortcutBindings.syntheticEventTag)

        keyDown.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms between key down and up
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
