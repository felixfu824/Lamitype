import Foundation
import os

/// Release diagnostics for one admitted dictation press. The formatter only
/// accepts stages and numeric metadata. Text is reduced to a count at entry.
struct DictationStageLog: Sendable {
    private static let logger = Logger(subsystem: "com.felix.hushtype", category: "dictation")

    enum AXReadPhase: String { case capture, observation, verification }
    enum CaptureEndReason: String { case durationCap = "duration_cap" }

    enum Stage {
        case pressAdmitted
        case captureStarted
        case captureEnded(sampleCount: Int, reason: CaptureEndReason? = nil)
        case transcriptionDone(charCount: Int, latencyMS: Int)
        case liveAXReadFailed(AXReadPhase, reason: LivePasteReason, elapsedMS: Int)
        case livePasteSkipped(LivePasteReason, charCount: Int, copyAvailable: Bool)
        case pasteDispatched(charCount: Int, focusedElementEditable: Bool)

        static func transcriptionDone(text: String, latency: TimeInterval) -> Self {
            .transcriptionDone(charCount: text.count, latencyMS: Int((latency * 1_000).rounded()))
        }

        static func pasteDispatched(text: String, focusedElementEditable: Bool) -> Self {
            .pasteDispatched(charCount: text.count, focusedElementEditable: focusedElementEditable)
        }
    }

    let pressID = UUID()

    func emit(_ stage: Stage) {
        // Notice events are available to log show under default retention.
        Self.logger.notice("\(format(stage), privacy: .public)")
    }

    func format(_ stage: Stage) -> String {
        let prefix = "press_id=\(pressID.uuidString) stage="
        switch stage {
        case .pressAdmitted:
            return prefix + "press_admitted"
        case .captureStarted:
            return prefix + "capture_started"
        case .captureEnded(let sampleCount, let reason):
            let suffix = reason.map { " reason=\($0.rawValue)" } ?? ""
            return prefix + "capture_ended duration_ms=\(sampleCount / 16) sample_count=\(sampleCount)" + suffix
        case .transcriptionDone(let charCount, let latencyMS):
            return prefix + "transcription_done char_count=\(charCount) latency_ms=\(latencyMS)"
        case .liveAXReadFailed(let phase, let reason, let elapsed):
            return prefix + "live_ax_read_failed phase=\(phase.rawValue) reason=\(reason.rawValue) elapsed_ms=\(elapsed)"
        case .livePasteSkipped(let reason, let count, let copyAvailable):
            return prefix + "live_paste_skipped reason=\(reason.rawValue) char_count=\(count) copy_available=\(copyAvailable)"
        case .pasteDispatched(let charCount, let focusedElementEditable):
            return prefix + "paste_dispatched focused_element_editable=\(focusedElementEditable) char_count=\(charCount)"
        }
    }
}
