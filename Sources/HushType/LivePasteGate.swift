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
        denialReason(captured: captured, current: current) == nil
    }

    /// Also used by the standalone probe; the first failed condition wins.
    static func denialReason(captured: Captured, current: Current) -> String? {
        guard let pid = captured.processIdentifier else { return "captured app unavailable" }
        guard current.processIdentifier == pid else { return "frontmost app changed" }
        guard !current.isTerminated else { return "captured app terminated" }
        guard current.isActive else { return "captured app inactive" }
        guard !current.activationChanged else { return "app activation changed" }
        guard !current.focusInvalidatedBeforeVerification else { return "focus/window notification latched" }
        guard !current.secureInputBeforeVerification else { return "secure input active before verification" }
        guard captured.hasWindow else { return "captured AX window unavailable" }
        guard current.windowMatches else { return "AX focused window changed or unavailable" }
        guard let windowID = captured.windowID else { return "captured CGWindowID unavailable" }
        guard current.windowID == windowID else { return "CGWindowID changed or unavailable" }
        if captured.hasElement {
            guard current.hasElement else { return "focused element disappeared" }
            guard current.elementMatches else { return "focused element changed" }
            guard current.subrole.isNonSecure else { return "secure or unreadable subrole" }
        } else {
            guard !current.hasElement else { return "focused element appeared" }
        }
        guard !current.focusInvalidatedAfterVerification else { return "focus/window notification latched during verification" }
        guard !current.secureInputAfterVerification else { return "secure input active after verification" }
        return nil
    }
}
