import AppKit
import XCTest
@testable import HushType

final class LiveInsertionTargetTests: XCTestCase {
    func testSubscribedTargetDoesNotQueryAXFromPreview() {
        let monitor = LiveFocusObservations()
        monitor.receivesBothNotifications = true
        monitor.sample { XCTFail("Preview performed synchronous AX IPC"); return nil }
        monitor.invalidate(.focusNotification)
        XCTAssertEqual(monitor.latchedReason, .focusNotification)
    }

    func testTimeoutCanRecoverButPositiveFocusChangeStaysLatched() {
        let monitor = LiveFocusObservations()
        monitor.sample { .axUnresponsive }
        monitor.sample { nil }
        XCTAssertNil(monitor.latchedReason)
        monitor.sample { .elementChanged }
        monitor.sample { XCTFail("A changed target should stay blocked"); return nil }
        XCTAssertEqual(monitor.latchedReason, .elementChanged)
    }

    func testTransportFailureIsNeverTreatedAsAnAbsentFocusedElement() {
        for (status, expected) in [(AXError.cannotComplete, LivePasteReason.axUnresponsive),
                                   (.invalidUIElement, .axReadFailed)] {
            var reads = 0
            let snapshot = LivePasteAXSnapshot(pid: getpid(), capturing: true, readsWindowID: false) { _, _, _ in
                reads += 1
                return status
            }
            XCTAssertEqual(snapshot.failure, expected)
            XCTAssertEqual(reads, 1, "Stop after the first failed request")
        }
    }

    @MainActor
    func testFocusChangeAtFinalCheckRollsBackClipboardAndSkipsDispatch() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("before", forType: .string))
        var checks = 0
        let reason = TextInserter.livePasteDenial("utterance", targetPID: getpid(), pasteboard: board) {
            checks += 1
            return checks == 3 ? .frontmostChanged : nil
        }
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(reason, .frontmostChanged)
        XCTAssertEqual(board.string(forType: .string), "before")
    }

    @MainActor
    func testCaptureTimeoutCopyPreservesNewerClipboardAndRequiresPermission() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.setString("original", forType: .string))
        let initial = board.changeCount
        XCTAssertFalse(TextInserter.copyLiveFallback("final", initialChangeCount: initial,
                                                     pasteboard: board) { false })
        XCTAssertEqual(board.string(forType: .string), "original")
        board.clearContents()
        XCTAssertTrue(board.setString("user copy", forType: .string))
        XCTAssertFalse(TextInserter.copyLiveFallback("final", initialChangeCount: initial,
                                                     pasteboard: board) { true })
        XCTAssertEqual(board.string(forType: .string), "user copy")
        XCTAssertTrue(TextInserter.copyLiveFallback("final", initialChangeCount: board.changeCount,
                                                    pasteboard: board) { true })
        XCTAssertEqual(board.string(forType: .string), "final")
    }

    @MainActor
    func testCaptureTimeoutCopyRevokesItsOwnWriteIfSecurityChanges() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var checks = 0
        XCTAssertFalse(TextInserter.copyLiveFallback("final", initialChangeCount: board.changeCount,
                                                     pasteboard: board) {
            checks += 1
            return checks == 1
        })
        XCTAssertEqual(checks, 2)
        XCTAssertNil(board.string(forType: .string))
    }

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
