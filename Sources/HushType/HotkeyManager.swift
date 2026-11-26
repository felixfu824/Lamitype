import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "hotkey")

/// Retained by admission work so a chord cannot be forgotten across callbacks
/// or confused with a later physical press.
final class DictationHotkeyPress {
    let key: ShortcutChord
    let began = ProcessInfo.processInfo.systemUptime
    fileprivate(set) var isCancelled = false
    let secureInputAtPress: Bool
    var secureInputAtAdmission: Bool?
    fileprivate(set) var keyDownCount = 0

    init(key: ShortcutChord, secureInputAtPress: Bool) {
        self.key = key; self.secureInputAtPress = secureInputAtPress
    }
}

final class HotkeyManager {
    /// Clears pending tap/double-tap work even when no key is currently held.
    var onBindingsWillChange: (() -> Void)?
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancelledRelease: ((RecordingCancellationReason) -> Void)?
    var onSecureInputIgnored: ((ShortcutChord, TimeInterval) -> Void)?
    var onChordDuringHold: (() -> Void)?
    /// Fires once per Live Caption shortcut press; repeats are suppressed.
    var onLiveCaptionToggle: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseTap: CFMachPort?
    private var mouseRunLoopSource: CFRunLoopSource?

    static let keyboardEventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    static let mouseEventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
    static let mouseTapOptions: CGEventTapOptions = .listenOnly
    private var isDictationDown = false
    private(set) var currentPress: DictationHotkeyPress?
    private var secureIgnoredPress: DictationHotkeyPress?
    #if DEBUG
    private(set) var disabledTapCount = 0
    private(set) var lastDisabledType = "none"
    private(set) var pressDispatches = 0
    private(set) var releaseDispatches = 0
    private(set) var proactiveEnableCount = 0
    private(set) var staleDisableCount = 0
    var tapEnabledForTesting: Bool { eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    private(set) var maximumCallbackSeconds: TimeInterval = 0
    var rightOptionIsDownForTesting: Bool { isDictationDown }
    #endif

    private(set) var bindings: ShortcutBindings
    private var watchdog: Timer?
    var onActionPress: ((ShortcutChord) -> Void)?
    var onActionRelease: ((ShortcutChord, TimeInterval) -> Void)?
    var onActionCancelled: (() -> Void)?
    var actionEnabled: (ShortcutAction) -> Bool = { _ in true }
    private var actionPress: (chord: ShortcutChord, began: TimeInterval)?
    private var consumedKeys = Set<CGKeyCode>()
    private var recordingObserver: NSObjectProtocol?
    private var recordingShortcut = false
    private var captionKeyConsumed = false
    private var consecutiveUpReadings = 0
    private let watchdogEnabled: Bool
    private let keyIsDown: (CGKeyCode) -> Bool
    private let keyboardTapEnabled: (CFMachPort?) -> Bool
    /// A set side bit can confirm a hold when keyState misses a virtual key.
    /// A clear bit cannot confirm a release delivered to the session tap.
    private let modifierFlags: (CGEventSourceStateID) -> UInt64
    private let secureInput: () -> Bool

    init(bindings: ShortcutBindings = .default,
         keyIsDown: ((CGKeyCode) -> Bool)? = nil,
         keyStateReader: @escaping (CGEventSourceStateID, CGKeyCode) -> Bool = { CGEventSource.keyState($0, key: $1) },
         modifierFlags: ((CGEventSourceStateID) -> UInt64)? = nil,
         keyboardTapEnabled: @escaping (CFMachPort?) -> Bool = { tap in
             tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
         },
         watchdogEnabled: Bool = HotkeyManager.watchdogAllowed(arguments: CommandLine.arguments),
         secureInput: @escaping () -> Bool = { SecureInputProbe.isActive() }) {
        self.bindings = bindings.valid ? bindings : .default
        self.keyIsDown = keyIsDown ?? { key in
            keyStateReader(.hidSystemState, key) || keyStateReader(.combinedSessionState, key)
        }
        // An injected key-state seam stays host-independent unless the test
        // also injects flags.
        self.modifierFlags = modifierFlags ?? (keyIsDown != nil
            ? { _ in 0 }
            : { CGEventSource.flagsState($0).rawValue })
        self.watchdogEnabled = watchdogEnabled
        self.keyboardTapEnabled = keyboardTapEnabled
        self.secureInput = secureInput
        recordingObserver = NotificationCenter.default.addObserver(forName: .shortcutRecorderChanged, object: nil,
                                                                    queue: .main) { [weak self] note in
            self?.recordingShortcut = note.object as? Bool == true
            self?.onBindingsWillChange?()
            self?.retireInterruptedHold()
        }
    }

    deinit { if let recordingObserver { NotificationCenter.default.removeObserver(recordingObserver) } }

    static func watchdogAllowed(arguments: [String]) -> Bool {
        #if DEBUG
        return !arguments.contains("--native-e2e")
        #else
        return true
        #endif
    }

    /// Retire before swapping, including when onboarding has not created a tap.
    func apply(_ bindings: ShortcutBindings) {
        precondition(Thread.isMainThread)
        guard bindings.valid else { return }
        onBindingsWillChange?()
        retireInterruptedHold()
        self.bindings = bindings
    }

    func checkForLostRelease() {
        guard watchdogEnabled else { return }
        if captionKeyConsumed, !keyIsDown(CGKeyCode(bindings.liveCaption.keyCode)) {
            captionKeyConsumed = false
        }
        // Global snapshots can stay clear for an entire posted modifier hold.
        // While the keyboard tap is delivering edges, wait for the bound key's
        // flagsChanged release. Poll only across a keyboard-tap outage.
        guard let key = currentPress?.key ?? secureIgnoredPress?.key ?? actionPress?.chord,
              !keyboardTapEnabled(eventTap), !dictationKeyIsDown(key) else {
            consecutiveUpReadings = 0
            return
        }
        consecutiveUpReadings += 1
        if consecutiveUpReadings >= 2 {
            log.info("Lost release watchdog: keyboard tap unavailable, key up on two samples")
            let disabledKeyboardTap = eventTap
            retireInterruptedHold()
            if let disabledKeyboardTap { enableIfStillDisabled(disabledKeyboardTap) }
        }
    }

    func dictationKeyIsDown(_ activeChord: ShortcutChord? = nil) -> Bool {
        guard let key = activeChord ?? bindings[.dictate].chord else { return false }
        if keyIsDown(key.keyCode) { return true }
        return (modifierFlags(.hidSystemState) | modifierFlags(.combinedSessionState)) & key.deviceBit != 0
    }

    /// Close only the hold that owns the capped recording. Its eventual up
    /// edge is unclaimed, and a fresh down can be accepted even if up was lost.
    func retireDurationCappedHold(_ press: DictationHotkeyPress) -> Bool {
        precondition(Thread.isMainThread)
        guard isDictationDown, currentPress === press, !press.isCancelled else { return false }
        logRelease(outcome: "duration_cap")
        isDictationDown = false
        currentPress = nil
        consecutiveUpReadings = 0
        return true
    }

    func start() {
        guard eventTap == nil else { return }

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            return manager.handleEvent(type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.keyboardEventMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            log.error("Failed to create CGEvent tap. Accessibility permission required.")
            promptAccessibilityPermission()
            return
        }

        let mouseCallback: CGEventTapCallBack = { _, type, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            return manager.handleMouseEvent(type: type, event: event)
        }
        guard let mouse = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: Self.mouseTapOptions, eventsOfInterest: Self.mouseEventMask,
            callback: mouseCallback, userInfo: selfPtr
        ) else {
            CFMachPortInvalidate(tap)
            log.error("Failed to create mouse observation tap. Accessibility permission required.")
            promptAccessibilityPermission()
            return
        }

        eventTap = tap
        mouseTap = mouse
        mouseRunLoopSource = CFMachPortCreateRunLoopSource(nil, mouse, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), mouseRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: mouse, enable: true)
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        if watchdogEnabled {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkForLostRelease() }
            watchdog = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        log.info("Hotkey manager started")
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        captionKeyConsumed = false
        retireInterruptedHold()
        for (tap, source) in [(eventTap, runLoopSource), (mouseTap, mouseRunLoopSource)] {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
                CFMachPortInvalidate(tap)
            }
        }
        eventTap = nil; runLoopSource = nil
        mouseTap = nil; mouseRunLoopSource = nil
        log.info("Hotkey manager stopped")
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        defer { maximumCallbackSeconds = max(maximumCallbackSeconds, ProcessInfo.processInfo.systemUptime - began) }
        #endif
        if recoverDisabledTap(type: type, tap: eventTap) {
            return Unmanaged.passUnretained(event)
        }

        // Ignore only our tagged copy/paste events, not DEBUG gesture posters.
        guard !recordingShortcut, event.getIntegerValueField(.eventSourceUserData) != ShortcutBindings.syntheticEventTag else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            if isDictationDown { currentPress?.keyDownCount += 1 }
            secureIgnoredPress?.keyDownCount += 1
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let code = CGKeyCode(exactly: keyCode) else { return Unmanaged.passUnretained(event) }
        if let ignored = secureIgnoredPress, keyCode != Int64(ignored.key.keyCode),
           !ignored.key.released(type: type, code: code, flags: event.flags),
           type == .keyDown || type == .keyUp || type == .flagsChanged {
            ignored.isCancelled = true
        }
        if type == .keyUp, captionKeyConsumed, keyCode == bindings.liveCaption.keyCode {
            captionKeyConsumed = false
            return nil
        }
        if type == .keyDown, captionKeyConsumed, keyCode == bindings.liveCaption.keyCode {
            return nil
        }
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let owningKey = currentPress?.key ?? secureIgnoredPress?.key
        let releasing = owningKey?.released(type: type, code: code, flags: event.flags) == true
        let actionReleasing = actionPress?.chord.released(type: type, code: code, flags: event.flags) == true
        let flagReleased = type == .flagsChanged && ShortcutChord.modifier(code).map { event.flags.rawValue & $0.bit == 0 } == true
        let capsReleased = type == .flagsChanged && code == 57 && event.flags.rawValue & ShortcutChord.physicalCapsMask == 0
        let consumedUp = (type == .keyUp || flagReleased || capsReleased) && consumedKeys.remove(code) != nil
        if consumedUp && !releasing && !actionReleasing { return nil }
        if type == .keyDown && !repeated { consumedKeys.remove(code) }
        if type == .keyDown && repeated && consumedKeys.contains(code) { return nil }
        let dictation = bindings[.dictate].chord
        let modifierBit = ShortcutChord.modifier(code)?.bit ?? (code == 63 ? CGEventFlags.maskSecondaryFn.rawValue : 0)
        let modifierChord = type == .flagsChanged && owningKey != .rightOption && code != owningKey?.keyCode
            && modifierBit & event.flags.rawValue != 0
        let isChord = !releasing && (type == .keyDown && code != owningKey?.keyCode || modifierChord)
        if isDictationDown && isChord && currentPress?.isCancelled == false {
            currentPress?.isCancelled = true
            onChordDuringHold?()
        }

        let edge: HotkeyEvent
        if bindings.edits.isEmpty {
            edge = bindings.classify(type: type, keyCode: keyCode, flags: event.flags, autorepeat: repeated)
        } else if releasing {
            edge = .dictationUp
        } else if !repeated, dictation?.matchesDown(type: type, code: code, flags: event.flags) == true {
            if actionPress != nil { actionPress = nil; onActionCancelled?() }
            edge = .dictationDown
        } else {
            return handleActionEdge(type: type, code: code, event: event, repeated: repeated, consumedUp: consumedUp)
        }
        switch edge {
        case .captionToggle:
            captionKeyConsumed = true
            onLiveCaptionToggle?()
            return nil
        case .captionRepeat:
            return nil
        case .dictationDown where !isDictationDown:
            if secureIgnoredPress != nil { return Unmanaged.passUnretained(event) }
            guard let dictation else { return Unmanaged.passUnretained(event) }
            let press = DictationHotkeyPress(key: dictation, secureInputAtPress: secureInput())
            if dictation != .rightOption, press.secureInputAtPress {
                // Keep only release/diagnostic metadata; no dictation lifecycle.
                press.isCancelled = bindings.edits.isEmpty && bindings.hasOtherModifierFamily(event.flags)
                secureIgnoredPress = press
                return Unmanaged.passUnretained(event)
            }
            if !bindings.edits.isEmpty { consumedKeys.insert(code) }
            isDictationDown = true
            consecutiveUpReadings = 0
            currentPress = press
            let preheldChord = bindings.edits.isEmpty && dictation != .rightOption && bindings.hasOtherModifierFamily(event.flags)
            press.isCancelled = preheldChord
            #if DEBUG
            pressDispatches += 1
            #endif
            onPress?()
            if preheldChord {
                onChordDuringHold?()
            }
            return nil
        case .dictationUp where secureIgnoredPress != nil:
            let press = secureIgnoredPress!
            secureIgnoredPress = nil
            consecutiveUpReadings = 0
            logRelease(outcome: "secureIgnored", press: press)
            if !press.isCancelled && secureInput() { onSecureInputIgnored?(press.key, press.began) }
            return Unmanaged.passUnretained(event)
        case .dictationUp where isDictationDown:
            isDictationDown = false
            consecutiveUpReadings = 0
            let wasChord = currentPress?.isCancelled == true
            logRelease(outcome: wasChord ? "cancelled" : "released")
            currentPress = nil
            if wasChord {
                onCancelledRelease?(.shortcutChord)
                // The focused app saw the chord's modifier flags. Let it see
                // those flags being released too, avoiding stuck modifier UI.
                return Unmanaged.passUnretained(event)
            }
            #if DEBUG
            releaseDispatches += 1
            #endif
            onRelease?()
            return consumedUp || bindings.edits.isEmpty ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleActionEdge(type: CGEventType, code: CGKeyCode, event: CGEvent,
                                  repeated: Bool, consumedUp: Bool) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let flags = event.flags
        if let active = actionPress {
            if active.chord.released(type: type, code: code, flags: flags) {
                actionPress = nil
                if !secureInput() { onActionRelease?(active.chord, ProcessInfo.processInfo.systemUptime - active.began) }
                else { onActionCancelled?() }
                return consumedUp ? nil : pass
            }
            if type == .keyDown || (type == .flagsChanged && (ShortcutChord.modifier(code)?.bit ?? 0) & flags.rawValue != 0) {
                actionPress = nil
                onActionCancelled?()
            }
        }
        guard !repeated, type == .keyDown || type == .flagsChanged else { return pass }
        guard let action = ShortcutAction.allCases.first(where: {
            $0 != .dictate && bindings[$0].chord?.matchesDown(type: type, code: code, flags: flags) == true && actionEnabled($0)
        }), let chord = bindings[action].chord, !secureInput() else { return pass }
        consecutiveUpReadings = 0
        if let press = currentPress, !press.isCancelled {
            press.isCancelled = true
            onChordDuringHold?()
        }
        actionPress = (chord, ProcessInfo.processInfo.systemUptime)
        consumedKeys.insert(code)
        onActionPress?(chord)
        return nil
    }

    /// Observation cannot hold up or suppress mouse delivery, even on a busy main loop.
    func handleMouseEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        if recoverDisabledTap(type: type, tap: mouseTap) { return Unmanaged.passUnretained(event) }
        let mouseDown = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        if mouseDown, let chord = currentPress?.key ?? secureIgnoredPress?.key ?? actionPress?.chord, chord != .rightOption,
           (chord.deviceBit == 0 || event.flags.rawValue & chord.deviceBit != 0),
           event.getIntegerValueField(.eventSourceUserData) != ShortcutBindings.syntheticEventTag {
            actionPress = nil
            onActionCancelled?()
            secureIgnoredPress?.isCancelled = true
            if let press = currentPress, !press.isCancelled {
                press.isCancelled = true
                onChordDuringHold?()
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func recoverDisabledTap(type: CGEventType, tap: CFMachPort?) -> Bool {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else { return false }
        #if DEBUG
        disabledTapCount += 1
        lastDisabledType = type == .tapDisabledByTimeout ? "timeout" : "by-user-input"
        #endif
        // A delayed notice must not retire a new hold after proactive resume.
        if let tap, CGEvent.tapIsEnabled(tap: tap) {
            #if DEBUG
            staleDisableCount += 1
            #endif
            return true
        }
        captionKeyConsumed = false
        retireInterruptedHold()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return true
    }

    private func retireInterruptedHold() {
        actionPress = nil
        onActionCancelled?()
        captionKeyConsumed = false
        if let press = secureIgnoredPress { logRelease(outcome: "secureIgnored", press: press) }
        secureIgnoredPress = nil
        let held = isDictationDown
        isDictationDown = false
        currentPress?.isCancelled = true
        if held { logRelease(outcome: "interrupted") }
        currentPress = nil
        consecutiveUpReadings = 0
        if held { onCancelledRelease?(.hotkeyInterrupted) }
    }

    private func logRelease(outcome: String, press: DictationHotkeyPress? = nil) {
        guard let press = press ?? currentPress else { return }
        let secureIgnored = press.key != .rightOption && (press.secureInputAtPress || press.secureInputAtAdmission == true)
        let result = secureIgnored ? "secureIgnored" : outcome
        log.info("Dictation press release: outcome=\(result, privacy: .public) keyDownCount=\(press.keyDownCount, privacy: .public) secureAtPress=\(press.secureInputAtPress, privacy: .public) admissionChecked=\(press.secureInputAtAdmission != nil, privacy: .public) secureAtAdmission=\(press.secureInputAtAdmission ?? false, privacy: .public)")
    }

    /// Resume only the already-authorized tap after native UI or completion.
    /// Never replay a key, recreate the tap, or ask for a permission grant.
    func resumeIfNeeded() {
        precondition(Thread.isMainThread)
        let disabled = [eventTap, mouseTap].compactMap { $0 }.filter { !CGEvent.tapIsEnabled(tap: $0) }
        guard !disabled.isEmpty else { return }
        captionKeyConsumed = false
        retireInterruptedHold()
        for tap in disabled { enableIfStillDisabled(tap) }
    }

    private func enableIfStillDisabled(_ tap: CFMachPort) {
        // Cancellation callbacks may stop the manager.
        guard [eventTap, mouseTap].contains(where: { $0.map { CFEqual($0, tap) } ?? false }),
              !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        #if DEBUG
        if CGEvent.tapIsEnabled(tap: tap) { proactiveEnableCount += 1 }
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
