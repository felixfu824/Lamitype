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
        viewer.window?.makeKeyAndOrderFront(nil)
        XCTAssertTrue(viewer.window!.isVisible)
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
