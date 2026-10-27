import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "hotkey")

final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancelledRelease: (() -> Void)?
    var onChordDuringHold: (() -> Void)?
    /// Fires on Right ⌘ + /. Single keyDown event — caller should treat it
    /// as a toggle (start if off, stop if running). Suppressed from
    /// propagation so the focused editor doesn't see it as a "toggle line
    /// comment" — note we only fire on the *right* command bit, so left
    /// ⌘ + / continues to work for editor comment-toggle as expected.
    var onLiveCaptionToggle: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRightOptionDown = false
    private var otherKeyPressedDuringHold = false
    #if DEBUG
    private(set) var disabledTapCount = 0
    private(set) var lastDisabledType = "none"
    private(set) var pressDispatches = 0
    private(set) var releaseDispatches = 0
    private(set) var proactiveEnableCount = 0
    private(set) var staleDisableCount = 0
    var tapEnabledForTesting: Bool { eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    private(set) var maximumCallbackSeconds: TimeInterval = 0
    var rightOptionIsDownForTesting: Bool { isRightOptionDown }
    #endif

    /// NX_DEVICERALTKEYMASK from IOKit/hidsystem/IOLLEvent.h. The aggregate
    /// Option flag stays set when Left Option is held during Right release.
    private static let rightOptionFlagBit: UInt64 = 0x40
    private static let rightOptionKeyCode: Int64 = 61 // kVK_RightOption
    /// kVK_ANSI_Slash — physical "/" key. With Shift held, this is "?".
    private static let slashKeyCode: Int64 = 44
    /// Device-dependent bit for Right Command on macOS CGEventFlags.
    /// The published `CGEventFlags.maskCommand` only encodes "some cmd is
    /// pressed"; left vs right lives in the lower byte of the raw value.
    /// 0x10 = right cmd; 0x08 = left cmd.
    private static let rightCommandFlagBit: UInt64 = 0x10
    private static let leftCommandFlagBit: UInt64 = 0x08

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            return manager.handleEvent(type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            log.error("Failed to create CGEvent tap. Accessibility permission required.")
            promptAccessibilityPermission()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        log.info("Hotkey manager started — listening for Right Option key")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        log.info("Hotkey manager stopped")
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        defer { maximumCallbackSeconds = max(maximumCallbackSeconds, ProcessInfo.processInfo.systemUptime - began) }
        #endif
        // Re-enable tap if it was disabled by the system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            #if DEBUG
            disabledTapCount += 1
            lastDisabledType = type == .tapDisabledByTimeout ? "timeout" : "by-user-input"
            #endif
            // Resumption after a native dialog can precede delivery of its
            // disable notice. Never let that stale notice cancel a fresh hold.
            if let tap = eventTap, CGEvent.tapIsEnabled(tap: tap) {
                #if DEBUG
                staleDisableCount += 1
                #endif
                return Unmanaged.passUnretained(event)
            }
            retireInterruptedHold()
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Track if other keys are pressed during Right Option hold
        if type == .keyDown && isRightOptionDown {
            if !otherKeyPressedDuringHold { onChordDuringHold?() }
            otherKeyPressedDuringHold = true
        }

        // Live Caption toggle: Right ⌘ + /. Single discrete keyDown. We
        // require the Right command bit specifically and forbid the Left
        // command bit so users who comment-toggle with left ⌘ + / in an
        // editor aren't disrupted. Shift is explicitly disallowed too so
        // "left ⌘ + ?" Help-menu and any "right ⌘ + ?" combos route
        // normally — only the bare "right ⌘ + /" combo triggers LC toggle.
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.slashKeyCode {
                let flagsRaw = event.flags.rawValue
                let rightCmd = (flagsRaw & Self.rightCommandFlagBit) != 0
                let leftCmd = (flagsRaw & Self.leftCommandFlagBit) != 0
                let shift = event.flags.contains(.maskShift)
                if rightCmd && !leftCmd && !shift {
                    log.debug("Live Caption hotkey (Right ⌘ + /)")
                    onLiveCaptionToggle?()
                    return nil // suppress — don't let editors interpret as comment-toggle
                }
            }
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.rightOptionKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let optionPressed = (flags.rawValue & Self.rightOptionFlagBit) != 0

        if optionPressed && !isRightOptionDown {
            // Right Option pressed
            isRightOptionDown = true
            otherKeyPressedDuringHold = false
            log.debug("Right Option pressed")
            #if DEBUG
            pressDispatches += 1
            #endif
            onPress?()
            return nil // suppress
        } else if !optionPressed && isRightOptionDown {
            // Right Option released
            isRightOptionDown = false
            log.debug("Right Option released (otherKeys: \(self.otherKeyPressedDuringHold))")
            if !otherKeyPressedDuringHold {
                #if DEBUG
                releaseDispatches += 1
                #endif
                onRelease?()
            } else {
                onCancelledRelease?()
            }
            return nil // suppress
        }

        return Unmanaged.passUnretained(event)
    }

    private func retireInterruptedHold() {
        let held = isRightOptionDown
        isRightOptionDown = false; otherKeyPressedDuringHold = false
        if held { onCancelledRelease?() }
    }

    /// Resume only the already-authorized tap after native UI or completion.
    /// Never replay a key, recreate the tap, or ask for a permission grant.
    func resumeIfNeeded() {
        precondition(Thread.isMainThread)
        guard let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        retireInterruptedHold()
        guard let current = eventTap, CFEqual(current, tap), !CGEvent.tapIsEnabled(tap: current) else { return }
        CGEvent.tapEnable(tap: current, enable: true)
        #if DEBUG
        if CGEvent.tapIsEnabled(tap: current) { proactiveEnableCount += 1 }
        #endif
    }
    #if DEBUG
    func nativeInterruptAndResume() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false); resumeIfNeeded()
    }
    func nativeDeliverStaleDisable() {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: false)!
        _ = handleEvent(type: .tapDisabledByTimeout, event: event)
    }
    #endif

    private func promptAccessibilityPermission() {
        // Last-resort fallback. In the normal flow, OnboardingManager.runIfNeeded()
        // catches missing-permission cases at launch BEFORE we ever call
        // CGEvent.tapCreate, so this code path should rarely fire. Reaching it
        // means the user revoked Accessibility while Lamitype was running, or
        // the kernel returned the cached "denied" state from a pre-grant call.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = L10n.string(
                "alert.accessibility_lost.title",
                fallback: "Accessibility Permission Lost"
            )
            alert.informativeText = L10n.string(
                "alert.accessibility_lost.message",
                fallback: "Lamitype lost Accessibility permission and the global hotkey is no longer working.\n\nRe-enable Lamitype in System Settings → Privacy & Security → Accessibility, then quit and relaunch Lamitype."
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.string(
                "common.button.open_system_settings",
                fallback: "Open System Settings"
            ))
            alert.addButton(withTitle: L10n.string("onboarding.button.quit", fallback: "Quit"))

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            } else {
                NSApp.terminate(nil)
            }
        }
    }
}
