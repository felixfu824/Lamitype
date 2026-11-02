import XCTest
@testable import HushType

final class LivePasteGateTests: XCTestCase {
    private var captured: LivePasteGate.Captured {
        .init(processIdentifier: 42, hasWindow: true, windowID: 130, hasElement: true)
    }
    private var current: LivePasteGate.Current {
        .init(processIdentifier: 42, isTerminated: false, isActive: true, activationChanged: false,
              focusInvalidatedBeforeVerification: false, focusInvalidatedAfterVerification: false,
              secureInputBeforeVerification: false, secureInputAfterVerification: false,
              windowMatches: true, windowID: 130, hasElement: true, elementMatches: true,
              role: "AXTextField", subrole: .value("AXSearchField"))
    }
    private func check(_ expected: String?,
                       capture: (inout LivePasteGate.Captured) -> Void = { _ in },
                       now: (inout LivePasteGate.Current) -> Void = { _ in },
                       file: StaticString = #filePath, line: UInt = #line) {
        var captured = captured
        var current = current
        capture(&captured)
        now(&current)
        XCTAssertEqual(LivePasteGate.denialReason(captured: captured, current: current), expected, file: file, line: line)
        XCTAssertEqual(LivePasteGate.allows(captured: captured, current: current), expected == nil, file: file, line: line)
    }

    func testUnchangedTextFieldAllows() { check(nil) }
    func testWebAreaAllowsWithoutValueSettableRequirement() { check(nil, now: { $0.role = "AXWebArea" }) }
    func testUnknownRoleAllows() { check(nil, now: { $0.role = "AXCustomControl" }) }
    func testUnavailableRoleAllows() { check(nil, now: { $0.role = nil }) }
    func testExplicitlyAbsentSubroleAllows() { check(nil, now: { $0.subrole = .absent }) }
    func testNoElementAtCaptureAndPasteAllows() {
        check(nil, capture: { $0.hasElement = false }, now: {
            $0.hasElement = false; $0.elementMatches = false; $0.subrole = .unreadable
        })
    }
    func testTwoConsecutiveUnchangedChunksAllow() {
        check(nil, now: { $0.role = "AXWebArea" })
        check(nil, now: { $0.role = "AXWebArea" })
    }
    func testMissingCapturedAppDenies() { check("captured app unavailable", capture: { $0.processIdentifier = nil }) }
    func testDifferentAppDenies() { check("frontmost app changed", now: { $0.processIdentifier = 43 }) }
    func testMissingCurrentAppDenies() { check("frontmost app changed", now: { $0.processIdentifier = nil }) }
    func testTerminatedAppDenies() { check("captured app terminated", now: { $0.isTerminated = true }) }
    func testInactiveAppDenies() { check("captured app inactive", now: { $0.isActive = false }) }
    func testActivationAwayAndBackDenies() { check("app activation changed", now: { $0.activationChanged = true }) }
    func testNotificationLatchedBeforeVerificationDenies() {
        check("focus/window notification latched", now: { $0.focusInvalidatedBeforeVerification = true })
    }
    func testSecureInputBeforeVerificationDenies() {
        check("secure input active before verification", now: { $0.secureInputBeforeVerification = true })
    }
    func testMissingCapturedWindowDenies() { check("captured AX window unavailable", capture: { $0.hasWindow = false }) }
    func testChangedOrMissingAXWindowDenies() {
        check("AX focused window changed or unavailable", now: { $0.windowMatches = false })
    }
    func testMissingCapturedCGWindowIDDenies() { check("captured CGWindowID unavailable", capture: { $0.windowID = nil }) }
    func testChangedCGWindowIDDenies() { check("CGWindowID changed or unavailable", now: { $0.windowID = 17205 }) }
    func testMissingCurrentCGWindowIDDenies() { check("CGWindowID changed or unavailable", now: { $0.windowID = nil }) }
    func testElementDisappearedDenies() { check("focused element disappeared", now: { $0.hasElement = false }) }
    func testChangedElementDenies() { check("focused element changed", now: { $0.elementMatches = false }) }
    func testSecureSubroleDenies() { check("secure or unreadable subrole", now: { $0.subrole = .value("AXSecureTextField") }) }
    func testUnreadableSubroleDenies() { check("secure or unreadable subrole", now: { $0.subrole = .unreadable }) }
    func testElementAppearingAfterNilCaptureDenies() { check("focused element appeared", capture: { $0.hasElement = false }) }
    func testNotificationLatchedDuringVerificationDenies() {
        check("focus/window notification latched during verification", now: { $0.focusInvalidatedAfterVerification = true })
    }
    func testSecureInputAfterVerificationDenies() {
        check("secure input active after verification", now: { $0.secureInputAfterVerification = true })
    }
}
