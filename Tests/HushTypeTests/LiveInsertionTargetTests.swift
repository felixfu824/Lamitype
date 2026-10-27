import AppKit
import XCTest
@testable import HushType

final class LiveInsertionTargetTests: XCTestCase {
    @MainActor func testSubroleRejectsSecureAndMalformedSuccessfulReads() {
        XCTAssertFalse(LiveInsertionTarget.isNonSecureSubrole(status: .success, value: kAXSecureTextFieldSubrole as CFString))
        XCTAssertTrue(LiveInsertionTarget.isNonSecureSubrole(status: .success, value: "AXSearchField" as CFString))
        XCTAssertFalse(LiveInsertionTarget.isNonSecureSubrole(status: .success, value: nil))
        XCTAssertFalse(LiveInsertionTarget.isNonSecureSubrole(status: .success, value: NSNumber(value: 1)))
    }
    @MainActor func testExplicitOptionalSubroleAbsenceIsDistinctFromFailure() {
        XCTAssertTrue(LiveInsertionTarget.isNonSecureSubrole(status: .attributeUnsupported, value: nil))
        XCTAssertTrue(LiveInsertionTarget.isNonSecureSubrole(status: .noValue, value: nil))
        XCTAssertFalse(LiveInsertionTarget.isNonSecureSubrole(status: .noValue, value: "unexpected" as CFString))
    }
    @MainActor func testTransportAndElementErrorsNeverAuthorizePaste() {
        let errors: [AXError] = [.cannotComplete, .invalidUIElement, .failure, .illegalArgument, .notImplemented]
        for status in errors {
            XCTAssertFalse(LiveInsertionTarget.isNonSecureSubrole(status: status, value: nil))
            XCTAssertFalse(LiveInsertionTarget.isNonSecureSubrole(status: status, value: "AXSearchField" as CFString))
        }
    }
}
