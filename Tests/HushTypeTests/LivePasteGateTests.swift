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
    private func check(_ expected: LivePasteReason?,
                       capture: (inout LivePasteGate.Captured) -> Void = { _ in },
                       now: (inout LivePasteGate.Current) -> Void = { _ in },
                       file: StaticString = #filePath, line: UInt = #line) {
        var captured = captured
        var current = current
        capture(&captured)
        now(&current)
        XCTAssertEqual(LivePasteGate.denial(captured: captured, current: current), expected, file: file, line: line)
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
    func testMissingCapturedAppDenies() { check(.missingApplication, capture: { $0.processIdentifier = nil }) }
    func testDifferentAppDenies() { check(.frontmostChanged, now: { $0.processIdentifier = 43 }) }
    func testMissingCurrentAppDenies() { check(.frontmostChanged, now: { $0.processIdentifier = nil }) }
    func testTerminatedAppDenies() { check(.terminated, now: { $0.isTerminated = true }) }
    func testInactiveAppDenies() { check(.inactive, now: { $0.isActive = false }) }
    func testActivationAwayAndBackDenies() { check(.activationChanged, now: { $0.activationChanged = true }) }
    func testNotificationLatchedBeforeVerificationDenies() {
        check(.focusNotification, now: { $0.focusInvalidatedBeforeVerification = true })
    }
    func testSecureInputBeforeVerificationDenies() {
        check(.secureBefore, now: { $0.secureInputBeforeVerification = true })
    }
    func testMissingCapturedWindowDenies() { check(.capturedWindowMissing, capture: { $0.hasWindow = false }) }
    func testChangedOrMissingAXWindowDenies() {
        check(.windowChanged, now: { $0.windowMatches = false })
    }
    func testMissingCapturedCGWindowIDDenies() { check(.capturedWindowIDMissing, capture: { $0.windowID = nil }) }
    func testChangedCGWindowIDDenies() { check(.windowIDChanged, now: { $0.windowID = 17205 }) }
    func testMissingCurrentCGWindowIDDenies() { check(.windowIDChanged, now: { $0.windowID = nil }) }
    func testElementDisappearedDenies() { check(.elementDisappeared, now: { $0.hasElement = false }) }
    func testChangedElementDenies() { check(.elementChanged, now: { $0.elementMatches = false }) }
    func testSecureSubroleDenies() { check(.secureSubrole, now: { $0.subrole = .value("AXSecureTextField") }) }
    func testUnreadableSubroleDenies() { check(.unreadableSubrole, now: { $0.subrole = .unreadable }) }
    func testElementAppearingAfterNilCaptureDenies() { check(.elementAppeared, capture: { $0.hasElement = false }) }
    func testNotificationLatchedDuringVerificationDenies() {
        check(.focusDuringVerification, now: { $0.focusInvalidatedAfterVerification = true })
    }
    func testSecureInputAfterVerificationDenies() {
        check(.secureAfter, now: { $0.secureInputAfterVerification = true })
    }
}
