import AppKit

/// Strict, fail-closed field identity. No app reactivation or best-effort PID paste.
@MainActor
final class LiveInsertionTarget {
    private nonisolated static let notifications = WeakNotificationRegistry<LiveFocusInvalidation>()
    private let focusInvalidation = LiveFocusInvalidation()
    let application: NSRunningApplication?
    private let field: AXUIElement?
    private let window: AXUIElement?
    private var observer: AXObserver?
    private var activationObserver: NSObjectProtocol?
    private(set) var changed = false

    init() {
        application = NSWorkspace.shared.frontmostApplication
        let appElement = application.map { AXUIElementCreateApplication($0.processIdentifier) }
        field = appElement.flatMap { Self.element($0, kAXFocusedUIElementAttribute) }
        window = field.flatMap { Self.element($0, kAXWindowAttribute) }
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

    func observe() { if focusInvalidation.isInvalidated || !matchesCurrentField() { changed = true } }
    func mayPaste() -> Bool {
        guard !changed, !focusInvalidation.isInvalidated, !SecureInputProbe.isActive(), matchesCurrentField() else { return false }
        // Synchronous AX queries can deliver native focus notifications. Honor
        // invalidation detected during verification before returning permission.
        return !SecureInputProbe.isActive() && !changed && !focusInvalidation.isInvalidated
    }

    private func matchesCurrentField() -> Bool {
        guard let application, !application.isTerminated, application.isActive,
              let field, let window,
              let current = Self.element(AXUIElementCreateApplication(application.processIdentifier), kAXFocusedUIElementAttribute),
              CFEqual(field, current), let currentWindow = Self.element(current, kAXWindowAttribute),
              CFEqual(window, currentWindow),
              let role = Self.string(current, kAXRoleAttribute),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return false }
        var subrole: CFTypeRef?
        let subroleStatus = AXUIElementCopyAttributeValue(current, kAXSubroleAttribute as CFString, &subrole)
        guard Self.isNonSecureSubrole(status: subroleStatus, value: subrole) else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(current, kAXValueAttribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    /// Subrole is optional for ordinary editable controls. Explicit absence is
    /// distinct from a timeout, invalid element or failed security-related read.
    static func isNonSecureSubrole(status: AXError, value: CFTypeRef?) -> Bool {
        switch status {
        case .success:
            guard let subrole = value as? String else { return false }
            return subrole != kAXSecureTextFieldSubrole
        case .attributeUnsupported, .noValue:
            return value == nil
        default:
            return false
        }
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
