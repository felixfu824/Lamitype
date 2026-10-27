import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "insertion")

struct TextInserter {
    static func insert(_ text: String) { _ = insertAttempt(text) }

    static func insertLive(_ text: String, targetPID: pid_t, verify: () -> Bool) -> Bool {
        guard targetPID > 0, !text.isEmpty, verify() else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        let oldInput = InputSourceManager.isCJKInputSourceActive() ? InputSourceManager.switchToASCII() : nil
        defer { if let oldInput { InputSourceManager.restore(inputSourceID: oldInput) } }
        if oldInput != nil { usleep(100_000) }
        guard verify() else { return false }
        let pasteboard = NSPasteboard.general
        let oldItems = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
                values[type] = item.data(forType: type)
            }
        } ?? []
        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        let writtenChangeCount = pasteboard.changeCount
        guard wrote, verify() else {
            // Abort without replacing a clipboard the user changed concurrently.
            if pasteboard.changeCount == writtenChangeCount {
                pasteboard.clearContents()
                pasteboard.writeObjects(oldItems.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
            }
            return false
        }
        // Deliver only to the application whose original field still passes
        // verification. Global HID delivery can paste twice in Claude Desktop.
        // Never fall back to a global event or reactivate a changed target.
        down.postToPid(targetPID)
        usleep(50_000)
        up.postToPid(targetPID)
        usleep(500_000)
        return true // Dispatch only; target acceptance is not observable.
    }

    private static func insertAttempt(_ text: String, verify: () -> Bool = { true }) -> Bool {
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
        guard verify() else {
            if let previousInputSourceID { InputSourceManager.restore(inputSourceID: previousInputSourceID) }
            return false
        }
        let sent = simulatePaste()
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

    private static func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        // kVK_ANSI_V = 0x09
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            print("[TextInserter] ERROR: Failed to create CGEvent")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms between key down and up
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
