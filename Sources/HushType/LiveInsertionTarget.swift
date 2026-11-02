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
    private var observer: AXObserver?
    private var activationObserver: NSObjectProtocol?
    private(set) var changed = false

    init() {
        application = NSWorkspace.shared.frontmostApplication
        let snapshot = application.map { LivePasteAXSnapshot(pid: $0.processIdentifier, capturing: true) }
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
                AXObserverAddNotification(axObserver, app, kAXFocusedUIElementChangedNotification as CFString, context)
                AXObserverAddNotification(axObserver, app, kAXFocusedWindowChangedNotification as CFString, context)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.changed = true } }
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
                AXObserverRemoveNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString)
                AXObserverRemoveNotification(observer, app, kAXFocusedWindowChangedNotification as CFString)
            }
        }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    /// Runs on every draft update, so it skips the system-wide CGWindowID read:
    /// a transient layer-0 child window (tab hover card, bubble) during recording
    /// must not latch `changed`. AX notifications stay the latching signal.
    func observe() { if focusInvalidation.isInvalidated || !matchesCurrentField(readsWindowID: false) { changed = true } }
    func mayPaste() -> Bool {
        guard !changed, !focusInvalidation.isInvalidated, !SecureInputProbe.isActive(), matchesCurrentField(readsWindowID: true) else { return false }
        // Synchronous AX queries can deliver native focus notifications. Honor
        // invalidation detected during verification before returning permission.
        return !SecureInputProbe.isActive() && !changed && !focusInvalidation.isInvalidated
    }

    private func matchesCurrentField(readsWindowID: Bool) -> Bool {
        let invalidatedBefore = focusInvalidation.isInvalidated
        let secureBefore = SecureInputProbe.isActive()
        let currentAX = application.map {
            LivePasteAXSnapshot(pid: $0.processIdentifier, capturing: false, readsWindowID: readsWindowID)
        }
        // AX reads can synchronously deliver native notifications. Sample the
        // latches and Secure Input only after all AX/CG identity reads complete.
        let secureAfter = SecureInputProbe.isActive()
        let current = LivePasteGate.Current(
            processIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            isTerminated: application?.isTerminated ?? true, isActive: application?.isActive ?? false,
            activationChanged: changed, focusInvalidatedBeforeVerification: invalidatedBefore,
            focusInvalidatedAfterVerification: focusInvalidation.isInvalidated,
            secureInputBeforeVerification: secureBefore, secureInputAfterVerification: secureAfter,
            windowMatches: LivePasteAXSnapshot.equal(capturedAX?.window, currentAX?.window),
            windowID: readsWindowID ? currentAX?.windowID : captured.windowID, hasElement: currentAX?.element != nil,
            elementMatches: LivePasteAXSnapshot.equal(capturedAX?.element, currentAX?.element),
            role: currentAX?.role, subrole: currentAX?.subrole ?? .unreadable
        )
        return LivePasteGate.allows(captured: captured, current: current)
    }

    /// Subrole is optional for ordinary editable controls. Explicit absence is
    /// distinct from a timeout, invalid element or failed security-related read.
    static func isNonSecureSubrole(status: AXError, value: CFTypeRef?) -> Bool {
        LivePasteAXSnapshot.subrole(status: status, value: value).isNonSecure
    }
}

/// System-read adapter shared with the standalone probe. Only value snapshots
/// and CFEqual identity results cross into LivePasteGate.
struct LivePasteAXSnapshot {
    let element: AXUIElement?
    let window: AXUIElement?
    let windowID: UInt32?
    let role: String?
    let subrole: LivePasteGate.Subrole

    init(pid: pid_t, capturing: Bool, readsWindowID: Bool = true) {
        let app = AXUIElementCreateApplication(pid)
        element = Self.element(app, kAXFocusedUIElementAttribute)
        if capturing {
            window = element.flatMap { Self.element($0, kAXWindowAttribute) }
                ?? Self.element(app, kAXFocusedWindowAttribute)
        } else {
            window = Self.element(app, kAXFocusedWindowAttribute)
        }
        windowID = readsWindowID ? Self.frontmostWindowID(pid: pid) : nil
        role = element.flatMap { Self.string($0, kAXRoleAttribute) }
        if let element {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
            subrole = Self.subrole(status: status, value: value)
        } else {
            subrole = .unreadable
        }
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

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
