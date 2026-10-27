import AppKit
import XCTest
@testable import HushType

@MainActor
final class LiveRecoveryWindowTests: XCTestCase {
    func testCompletedTextStaysHiddenUntilExplicitOpen() {
        _ = NSApplication.shared
        let viewer = LiveRecoveryWindow()
        defer { viewer.close() }
        viewer.storeResult(text: "Retained result", message: "Text ready")
        XCTAssertFalse(viewer.window!.isVisible)
        XCTAssertEqual(viewer.text, "Retained result")
        viewer.showStoredResult()
        XCTAssertTrue(viewer.window!.isVisible)
    }
    func testDeferredFrontingCannotReopenANewerCompletedResult() async {
        _ = NSApplication.shared
        let viewer = LiveRecoveryWindow()
        defer { viewer.close() }
        viewer.storeResult(text: "Previous result", message: "Text ready")
        viewer.showStoredResult()
        viewer.storeResult(text: "New result", message: "Text ready")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertFalse(viewer.window!.isVisible)
        XCTAssertEqual(viewer.text, "New result")
    }
    func testReopeningRecoveryPreservesRetryState() {
        _ = NSApplication.shared
        let viewer = LiveRecoveryWindow()
        defer { viewer.close() }
        viewer.present(message: "Recognition failed", hasAudio: true)
        viewer.working = true
        viewer.showStoredResult()
        XCTAssertTrue(viewer.window!.isVisible)
        XCTAssertTrue(viewer.hasAudio)
        XCTAssertTrue(viewer.working)
    }
    func testLastResultCanBeCopiedAgainAfterClipboardChanges() {
        _ = NSApplication.shared
        let viewer = LiveRecoveryWindow()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { viewer.close(); pasteboard.clearContents() }
        viewer.storeResult(text: "最近一次辨識結果", message: "Text ready")
        for _ in 0..<2 {
            pasteboard.clearContents()
            pasteboard.setString("Different clipboard content", forType: .string)
            viewer.showStoredResult()
            viewer.copy(to: pasteboard)
            XCTAssertEqual(pasteboard.string(forType: .string), "最近一次辨識結果")
            XCTAssertEqual(viewer.text, "最近一次辨識結果")
            XCTAssertFalse(viewer.window!.isVisible)
        }
    }
    func testRetryCompletionClosesFailurePanelAndClearsAudioState() {
        _ = NSApplication.shared
        let viewer = LiveRecoveryWindow()
        defer { viewer.close() }
        viewer.present(message: "Recognition failed", hasAudio: true)
        viewer.working = true
        XCTAssertTrue(viewer.window!.isVisible)
        viewer.storeResult(text: "Recovered text", message: "Text ready")
        XCTAssertFalse(viewer.window!.isVisible)
        XCTAssertFalse(viewer.hasAudio)
        XCTAssertFalse(viewer.working)
        XCTAssertEqual(viewer.text, "Recovered text")
    }
    func testReadyNoticeIsNotRenderedAsRecordingFailure() {
        let model = OverlayStateModel()
        let ticket = model.beginNotice(message: "Open Last Live Result to copy", style: .information(heading: "Text ready"))
        XCTAssertTrue(model.isShowingNotice)
        XCTAssertFalse(model.isShowingFailureNotice)
        XCTAssertTrue(model.expireNotice(ticket))
        XCTAssertFalse(model.isShowingNotice)
        _ = model.beginNotice(message: "No microphone")
        XCTAssertTrue(model.isShowingFailureNotice)
    }
}
