/// Fixed public diagnostic tokens. No field contents or app identifiers.
enum LivePasteReason: String {
    case targetUnverified = "target_unverified"
    case missingApplication = "missing_application"
    case frontmostChanged = "frontmost_changed"
    case terminated = "terminated"
    case inactive = "inactive"
    case activationChanged = "activation_changed"
    case focusNotification = "focus_notification"
    case secureBefore = "secure_before"
    case capturedWindowMissing = "captured_window_missing"
    case windowChanged = "window_changed"
    case capturedWindowIDMissing = "captured_window_id_missing"
    case windowIDChanged = "window_id_changed"
    case elementDisappeared = "element_disappeared"
    case elementChanged = "element_changed"
    case secureSubrole = "secure_subrole"
    case elementAppeared = "element_appeared"
    case focusDuringVerification = "focus_during_verification"
    case secureAfter = "secure_after"
    case axUnresponsive = "ax_unresponsive"
    case axReadFailed = "ax_read_failed"
    case capturedAXUnresponsive = "captured_ax_unresponsive"
    case capturedAXReadFailed = "captured_ax_read_failed"
    case unreadableSubrole = "unreadable_subrole"
    case retryCopyOnly = "retry_copy_only"
    case eventCreation = "event_creation"
    case clipboardWrite = "clipboard_write"
    case emptyText = "empty_text"
    case cancelled = "cancelled"
    case superseded = "superseded"
    case secureInput = "secure_input"
    case recognitionFailed = "recognition_failed"
    case preparationUnavailable = "preparation_unavailable"
    case missingRecipient = "missing_recipient"
}

/// Pure policy for Live's final paste. AX identities are compared by the caller;
/// this layer contains no AX objects, application handles, or system reads.
enum LivePasteGate {
    struct Captured {
        var processIdentifier: Int32?
        var hasWindow: Bool
        var windowID: UInt32?
        var hasElement: Bool
    }

    enum Subrole {
        case value(String)
        case absent
        case unreadable

        var isNonSecure: Bool {
            switch self {
            case .value(let value): return value != "AXSecureTextField"
            case .absent: return true
            case .unreadable: return false
            }
        }
    }

    struct Current {
        var processIdentifier: Int32?
        var isTerminated: Bool
        var isActive: Bool
        var activationChanged: Bool
        var focusInvalidatedBeforeVerification: Bool
        var focusInvalidatedAfterVerification: Bool
        var secureInputBeforeVerification: Bool
        var secureInputAfterVerification: Bool
        var windowMatches: Bool
        var windowID: UInt32?
        var hasElement: Bool
        var elementMatches: Bool
        var role: String?  // Diagnostic only (probe output); the policy ignores roles.
        var subrole: Subrole
    }

    static func allows(captured: Captured, current: Current) -> Bool {
        denial(captured: captured, current: current) == nil
    }

    /// Keep the standalone probe on the same policy as the app.
    static func denialReason(captured: Captured, current: Current) -> String? {
        denial(captured: captured, current: current)?.rawValue
    }

    static func denial(captured: Captured, current: Current) -> LivePasteReason? {
        guard let pid = captured.processIdentifier else { return .missingApplication }
        guard current.processIdentifier == pid else { return .frontmostChanged }
        guard !current.isTerminated else { return .terminated }
        guard current.isActive else { return .inactive }
        guard !current.activationChanged else { return .activationChanged }
        guard !current.focusInvalidatedBeforeVerification else { return .focusNotification }
        guard !current.secureInputBeforeVerification else { return .secureBefore }
        guard captured.hasWindow else { return .capturedWindowMissing }
        guard current.windowMatches else { return .windowChanged }
        guard let windowID = captured.windowID else { return .capturedWindowIDMissing }
        guard current.windowID == windowID else { return .windowIDChanged }
        if captured.hasElement {
            guard current.hasElement else { return .elementDisappeared }
            guard current.elementMatches else { return .elementChanged }
            if case .unreadable = current.subrole { return .unreadableSubrole }
            guard current.subrole.isNonSecure else { return .secureSubrole }
        } else {
            guard !current.hasElement else { return .elementAppeared }
        }
        guard !current.focusInvalidatedAfterVerification else { return .focusDuringVerification }
        guard !current.secureInputAfterVerification else { return .secureAfter }
        return nil
    }
}
