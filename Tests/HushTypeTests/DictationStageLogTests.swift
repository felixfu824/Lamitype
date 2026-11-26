import XCTest
@testable import HushType

final class DictationStageLogTests: XCTestCase {
    func testStageFormatUsesOnePressID() {
        let log = DictationStageLog()
        let prefix = "press_id=\(log.pressID.uuidString) stage="
        XCTAssertNotEqual(log.pressID, DictationStageLog().pressID)
        XCTAssertEqual(log.format(.pressAdmitted), prefix + "press_admitted")
        XCTAssertEqual(log.format(.captureStarted), prefix + "capture_started")
        XCTAssertEqual(log.format(.captureEnded(sampleCount: 16_015)),
                       prefix + "capture_ended duration_ms=1000 sample_count=16015")
        XCTAssertEqual(log.format(.captureEnded(sampleCount: 9_600_000, reason: .durationCap)),
                       prefix + "capture_ended duration_ms=600000 sample_count=9600000 reason=duration_cap")
    }

    func testTextBearingStagesEmitOnlyCharacterCounts() {
        let log = DictationStageLog()
        let sentinel = "PRIVATE_TRANSCRIPT_👩🏽‍💻\n機密"
        let prefix = "press_id=\(log.pressID.uuidString) stage="
        let transcription = log.format(.transcriptionDone(text: sentinel, latency: 0.2546))
        let editablePaste = log.format(.pasteDispatched(text: sentinel, focusedElementEditable: true))
        let otherPaste = log.format(.pasteDispatched(text: sentinel, focusedElementEditable: false))
        XCTAssertEqual(transcription, prefix + "transcription_done char_count=23 latency_ms=255")
        XCTAssertEqual(editablePaste, prefix + "paste_dispatched focused_element_editable=true char_count=23")
        XCTAssertEqual(otherPaste, prefix + "paste_dispatched focused_element_editable=false char_count=23")
        let recovery = log.format(.livePasteSkipped(.axUnresponsive, charCount: sentinel.count, copyAvailable: true))
        XCTAssertEqual(recovery, prefix + "live_paste_skipped reason=ax_unresponsive char_count=23 copy_available=true")
        XCTAssertEqual(log.format(.liveAXReadFailed(.verification, reason: .axUnresponsive, elapsedMS: 75)),
                       prefix + "live_ax_read_failed phase=verification reason=ax_unresponsive elapsed_ms=75")
        for line in [transcription, editablePaste, otherPaste, recovery] {
            XCTAssertFalse(line.contains(sentinel))
        }
    }
}
