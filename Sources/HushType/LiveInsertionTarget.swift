import AppKit

/// Live paste requires the original active app, unchanged AX window and CGWindowID,
/// and unchanged focused element when one is exposed. Activation/focus changes and
/// secure input block delivery. No app reactivation is attempted. Accepted risk:
/// apps exposing no focused element cannot reveal moves within the same window
/// (including cells or document tabs); window identity still has to match.
@MainActor
final class LiveInsertionTarget {
    private nonisolated static let notifications = WeakNotificationRegistry<LiveFocusInvalidation>()
    private let focusInvalidation = LiveFocusInvalidation()
    let application: NSRunningApplication?
    private let capturedAX: LivePasteAXSnapshot?
    private let captured: LivePasteGate.Captured
    private let initialPasteboardChangeCount: Int
    private var observer: AXObserver?
    private var activationObserver: NSObjectProtocol?
    private let observations = LiveFocusObservations()
    private let stageLog: DictationStageLog

    init(stageLog: DictationStageLog) {
        self.stageLog = stageLog
        initialPasteboardChangeCount = NSPasteboard.general.changeCount
        application = NSWorkspace.shared.frontmostApplication
        let snapshot = application.map { LivePasteAXSnapshot(pid: $0.processIdentifier, capturing: true) }
        snapshot?.logFailure(to: stageLog, phase: .capture)
        capturedAX = snapshot
        captured = LivePasteGate.Captured(
            processIdentifier: application?.processIdentifier, hasWindow: snapshot?.window != nil,
            windowID: snapshot?.windowID, hasElement: snapshot?.element != nil
        )
        if let application {
            var axObserver: AXObserver?
            if AXObserverCreate(application.processIdentifier, { _, _, _, context in
                guard let context else { return }
                let token = UInt(bitPattern: context)
                // No actor-executor checks or UI access at this native boundary.
                // Latch synchronously so even an away-and-back focus change
                // queued before final delivery permanently blocks auto-paste.
                LiveInsertionTarget.notifications.owner(for: token)?.invalidate()
            }, &axObserver) == .success, let axObserver {
                observer = axObserver
                let context = UnsafeMutableRawPointer(bitPattern: Self.notifications.register(focusInvalidation))!
                let app = AXUIElementCreateApplication(application.processIdentifier)
                if AXUIElementSetMessagingTimeout(app, LivePasteAXSnapshot.timeout) == .success {
                    let field = AXObserverAddNotification(axObserver, app, kAXFocusedUIElementChangedNotification as CFString, context)
                    let window = AXObserverAddNotification(axObserver, app, kAXFocusedWindowChangedNotification as CFString, context)
                    observations.receivesBothNotifications = field == .success && window == .success
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.observations.invalidate(.activationChanged) } }
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            let pid = application?.processIdentifier
            // Deallocation can occur inside a VoiceOver/AX Discard action.
            // Synchronous unsubscription from our own app reenters AX's lock.
            // The removed source and expired weak token already prevent writes;
            // retain only the observer until cleanup runs after that action.
            DispatchQueue.main.async {
                guard let pid else { return }
                let app = AXUIElementCreateApplication(pid)
                guard AXUIElementSetMessagingTimeout(app, LivePasteAXSnapshot.timeout) == .success else { return }
                AXObserverRemoveNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString)
                AXObserverRemoveNotification(observer, app, kAXFocusedWindowChangedNotification as CFString)
            }
        }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    /// Subscribed apps deliver away-and-back changes without a synchronous IPC
    /// from the 100 ms UI timer. For partial observer support keep the original
    /// polling safety net. A timed-out sample says nothing about identity.
    /// The final read must independently establish the full original target.
    func observe() {
        // A failed capture can never be verified for paste. Leave the change
        // latch available for actual activation and focus notifications.
        guard capturedAX?.failure == nil else { return }
        observations.sample { denial(readsWindowID: false) }
    }

    /// With no original field identity, the user chooses where to paste. Only
    /// offer automatic Copy once AX can confirm a nonsecure focused control.
    func copyAfterCaptureTimeout(_ text: String) -> Bool {
        guard capturedAX?.failure == .axUnresponsive, let application else { return false }
        let pid = application.processIdentifier
        func stillActive() -> Bool {
            application.isActive && !application.isTerminated
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && observations.latchedReason == nil && !focusInvalidation.isInvalidated
                && !SecureInputProbe.isActive()
        }
        guard stillActive() else { return false }
        let focus = LivePasteAXSnapshot(pid: pid, capturing: false, readsWindowID: false)
        guard focus.failure == nil, focus.element != nil, focus.subrole.isNonSecure else { return false }
        return TextInserter.copyLiveFallback(text, initialChangeCount: initialPasteboardChangeCount,
                                            isAllowed: stillActive)
    }

    func denial(readsWindowID: Bool = true) -> LivePasteReason? {
        if let reason = observations.latchedReason { return reason }
        if focusInvalidation.isInvalidated { return .focusNotification }
        guard !SecureInputProbe.isActive() else { return .secureInput }
        guard let application else { return .missingApplication }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            return .frontmostChanged
        }
        if let failure = capturedAX?.failure {
            return failure == .axUnresponsive ? .capturedAXUnresponsive : .capturedAXReadFailed
        }
        let invalidatedBefore = focusInvalidation.isInvalidated
        let secureBefore = SecureInputProbe.isActive()
        let currentAX = LivePasteAXSnapshot(pid: application.processIdentifier, capturing: false, readsWindowID: readsWindowID)
        if let failure = currentAX.failure {
            currentAX.logFailure(to: stageLog, phase: readsWindowID ? .verification : .observation)
            return failure
        }
        // AX reads can synchronously deliver native notifications. Sample the
        // latches and Secure Input only after all AX/CG identity reads complete.
        let secureAfter = SecureInputProbe.isActive()
        let current = LivePasteGate.Current(
            processIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            isTerminated: application.isTerminated, isActive: application.isActive,
            activationChanged: observations.latchedReason != nil, focusInvalidatedBeforeVerification: invalidatedBefore,
            focusInvalidatedAfterVerification: focusInvalidation.isInvalidated,
            secureInputBeforeVerification: secureBefore, secureInputAfterVerification: secureAfter,
            windowMatches: LivePasteAXSnapshot.equal(capturedAX?.window, currentAX.window),
            windowID: readsWindowID ? currentAX.windowID : captured.windowID, hasElement: currentAX.element != nil,
            elementMatches: LivePasteAXSnapshot.equal(capturedAX?.element, currentAX.element),
            role: nil, subrole: currentAX.subrole
        )
        return LivePasteGate.denial(captured: captured, current: current)
    }

    /// Subrole is optional for ordinary editable controls. Explicit absence is
    /// distinct from a timeout, invalid element or failed security-related read.
    static func isNonSecureSubrole(status: AXError, value: CFTypeRef?) -> Bool {
        LivePasteAXSnapshot.subrole(status: status, value: value).isNonSecure
    }
}

/// Retain the first observed change. A transport timeout during a partial
/// observation is inconclusive; at dispatch the full identity check is mandatory.
final class LiveFocusObservations {
    var receivesBothNotifications = false
    private(set) var latchedReason: LivePasteReason?

    func invalidate(_ reason: LivePasteReason) {
        if latchedReason == nil { latchedReason = reason }
    }

    func sample(_ read: () -> LivePasteReason?) {
        guard !receivesBothNotifications, latchedReason == nil else { return }
        if let denial = read(), denial != .axUnresponsive { invalidate(denial) }
    }
}

/// System-read adapter shared with the standalone probe. Only value snapshots
/// and CFEqual identity results cross into LivePasteGate.
struct LivePasteAXSnapshot {
    static let timeout: Float = 0.075
    private(set) var element: AXUIElement?
    private(set) var window: AXUIElement?
    private(set) var windowID: UInt32?
    // Only the standalone diagnostic probe needs the role.
    var role: String? {
        guard let element, AXUIElementSetMessagingTimeout(element, Self.timeout) == .success else { return nil }
        return Self.string(element, kAXRoleAttribute)
    }
    private(set) var elapsedMS = 0
    private(set) var subrole: LivePasteGate.Subrole = .unreadable
    private(set) var failure: LivePasteReason?

    init(pid: pid_t, capturing: Bool, readsWindowID: Bool = true,
         read: (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyAttributeValue) {
        let app = AXUIElementCreateApplication(pid)
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + Double(Self.timeout)
        var firstFailure: LivePasteReason?

        func value(_ object: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard firstFailure == nil else { return nil }
            let remaining = Float(deadline - ProcessInfo.processInfo.systemUptime)
            guard remaining > 0 else { firstFailure = .axUnresponsive; return nil }
            guard AXUIElementSetMessagingTimeout(object, remaining) == .success else {
                firstFailure = .axReadFailed
                return nil
            }
            var value: CFTypeRef?
            switch read(object, attribute as CFString, &value) {
            case .success where value != nil: return value
            case .noValue, .attributeUnsupported:
                if value != nil { firstFailure = .axReadFailed }
            case .cannotComplete: firstFailure = .axUnresponsive
            default: firstFailure = .axReadFailed
            }
            return nil
        }
        func axElement(_ object: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let value = value(object, attribute) else { return nil }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                firstFailure = .axReadFailed
                return nil
            }
            return (value as! AXUIElement)
        }
        element = axElement(app, kAXFocusedUIElementAttribute)
        if capturing, let element { window = axElement(element, kAXWindowAttribute) }
        if window == nil { window = axElement(app, kAXFocusedWindowAttribute) }
        if let element, !capturing {
            if let result = value(element, kAXSubroleAttribute) {
                subrole = (result as? String).map(LivePasteGate.Subrole.value) ?? .unreadable
            } else if firstFailure == nil {
                subrole = .absent
            }
        }
        elapsedMS = Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
        failure = firstFailure
        if readsWindowID, failure == nil { windowID = Self.frontmostWindowID(pid: pid) }
    }

    func logFailure(to log: DictationStageLog, phase: DictationStageLog.AXReadPhase) {
        if let failure { log.emit(.liveAXReadFailed(phase, reason: failure, elapsedMS: elapsedMS)) }
    }

    static func equal(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return false }
        return CFEqual(lhs, rhs)
    }

    static func subrole(status: AXError, value: CFTypeRef?) -> LivePasteGate.Subrole {
        switch status {
        case .success:
            return (value as? String).map { .value($0) } ?? .unreadable
        case .attributeUnsupported, .noValue:
            return value == nil ? .absent : .unreadable
        default:
            return .unreadable
        }
    }

    private static func frontmostWindowID(pid: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // CGWindowListCopyWindowInfo returns windows in front-to-back order.
        return windows.first {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }.flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
