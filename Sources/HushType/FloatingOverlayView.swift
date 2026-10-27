import SwiftUI
import AppKit

// MARK: - State

/// Visible state of the floating overlay. The window itself is shown/hidden
/// independently — `.hidden` is here only for clarity, in practice the window
/// is ordered out instead of rendering this case.
enum OverlayNoticeStyle: Equatable { case failure, information(heading: String) }

enum OverlayState: Equatable {
    case hidden
    case recording(level: Float, provider: String?)  // 0.0–1.0 RMS
    case transcribing(provider: String?)
    case polishing
    /// Brief non-modal failure notice. The payload is already-localized plain
    /// text, never a localization key and never Markdown.
    case notice(message: String, style: OverlayNoticeStyle = .failure)
}

/// Identity for one displayed notice. Two notices can carry identical wording,
/// so a pending expiry is matched by object identity and never by message.
final class NoticeTicket {}

/// Observable model so SwiftUI can react to RMS updates.
///
/// Thread-safety: All mutations of `state` MUST happen on the main thread.
/// AppDelegate enforces this by hopping to main before forwarding RMS
/// callbacks (which fire on the CoreAudio IO thread). Not @MainActor-annotated
/// to keep AppDelegate construction synchronous.
struct LiveOverlayState {
    var phase: LiveDictationPhase = .recording
    var draft = ""
    var elapsed: TimeInterval = 0
    var earlierDraftHidden = false
    var stoppedAtLimit = false
    var previewUnavailable = false
}

final class OverlayStateModel: ObservableObject {
    @Published var live: LiveOverlayState?
    @Published var liveLevel: Float = 0
    @Published var liveNotice: String?
    @Published var state: OverlayState = .hidden {
        didSet {
            // Any transition away from a notice retires its ticket, so a timer
            // still in flight can never hide whatever replaced it.
            if case .notice = state { return }
            noticeTicket = nil
        }
    }

    /// Owner of the notice currently on screen, if any. Main-thread owned.
    private var noticeTicket: NoticeTicket?

    /// True while a transient failure or information notice is visible.
    var isShowingNotice: Bool {
        if case .notice = state { return true }
        return false
    }

    var isShowingFailureNotice: Bool {
        if case .notice(_, .failure) = state { return true }
        return false
    }

    /// Show `message` as a notice and take ownership of it, replacing any
    /// notice already on screen.
    @discardableResult
    func beginNotice(message: String, style: OverlayNoticeStyle = .failure) -> NoticeTicket {
        let ticket = NoticeTicket()
        state = .notice(message: message, style: style)
        noticeTicket = ticket
        return ticket
    }

    /// Retire the active ticket, and hide only if a notice is what is showing.
    func invalidateNotice() {
        noticeTicket = nil
        if case .notice = state {
            state = .hidden
        }
    }

    /// Hide the notice this exact ticket owns. Returns true only when it did,
    /// so a stale timer can tell that it has nothing to dismiss.
    func expireNotice(_ ticket: NoticeTicket) -> Bool {
        guard noticeTicket === ticket else { return false }
        guard case .notice = state else { return false }
        state = .hidden
        return true
    }
}

// MARK: - Pill view

enum FloatingOverlayGeometry {
    static let cornerRadius: CGFloat = 16
    static let previewWidth: CGFloat = 380
    static let previewHeight: CGFloat = 144
    static let progressWidth: CGFloat = previewWidth
    static let progressHeight: CGFloat = 48
    static let panelGap: CGFloat = 16

    static func liveSilhouette(in bounds: CGRect, flipped: Bool) -> CGPath {
        let path = CGMutablePath()
        let previewY = flipped ? bounds.minY : bounds.minY + progressHeight + panelGap
        let progressY = flipped ? bounds.maxY - progressHeight : bounds.minY
        path.addRoundedRect(in: CGRect(x: bounds.midX - previewWidth / 2, y: previewY,
            width: previewWidth, height: previewHeight), cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        path.addRoundedRect(in: CGRect(x: bounds.midX - progressWidth / 2, y: progressY,
            width: progressWidth, height: progressHeight), cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        return path
    }
}

struct FloatingOverlayView: View {
    @ObservedObject var model: OverlayStateModel

    var body: some View {
        Group {
            if let live = model.live { liveContent(live) }
            else { ordinaryContent }
        }
    }

    private func liveContent(_ live: LiveOverlayState) -> some View {
        VStack(spacing: FloatingOverlayGeometry.panelGap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(live.previewUnavailable && live.phase == .recording
                     ? L10n.string("live.draft.unavailable", fallback: "Preview unavailable · release to finalize")
                     : live.earlierDraftHidden
                     ? L10n.string("live.draft.earlier", fallback: "Earlier draft hidden · all text may change")
                     : L10n.string("live.draft.label", fallback: "Draft · may change"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(height: 14, alignment: .leading)
                Text(live.draft.isEmpty
                     ? (live.phase != .recording
                        ? L10n.string("live.stopped", fallback: "Recording stopped")
                        : live.elapsed >= 6 ? L10n.string("live.draft.slow", fallback: "Still listening… Preview is taking longer.") : L10n.string("live.draft.waiting", fallback: "Listening… Draft text will appear here."))
                     : live.draft)
                    .font(.system(size: 14)).lineLimit(3).truncationMode(.head)
                    .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .topLeading)
                Text(liveHint(live))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            }
            .padding(14)
            .frame(width: FloatingOverlayGeometry.previewWidth, height: FloatingOverlayGeometry.previewHeight)
            .background(VisualEffectBlur(material: .hudWindow))
            .clipShape(RoundedRectangle(cornerRadius: FloatingOverlayGeometry.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FloatingOverlayGeometry.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5))

            // Live preview, Live progress and ordinary activity share a width.
            // Retain the ordinary indicator's height, corners and screen anchor.
            HStack(spacing: 10) {
                Image(systemName: live.phase == .recording ? "mic.fill" : "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                Text(liveLabel(live.phase)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if live.phase == .recording { AudioBarsView(level: model.liveLevel).frame(width: 36) }
                Text(String(format: "%02d:%02d / 01:00", Int(min(60, live.elapsed)) / 60, Int(min(60, live.elapsed)) % 60))
                    .font(.system(size: 12).monospacedDigit()).fixedSize().layoutPriority(1)
            }
            .padding(.horizontal, 18)
            .frame(width: FloatingOverlayGeometry.progressWidth, height: FloatingOverlayGeometry.progressHeight)
            .background {
                GeometryReader { geometry in
                    Rectangle().fill(Color.primary.opacity(0.10))
                        .frame(width: geometry.size.width * min(1, max(0, live.elapsed / 60)))
                }.background(VisualEffectBlur(material: .hudWindow))
            }
            .clipShape(RoundedRectangle(cornerRadius: FloatingOverlayGeometry.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FloatingOverlayGeometry.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .frame(width: FloatingOverlayGeometry.previewWidth)
        .fixedSize()
    }

    private func liveHint(_ live: LiveOverlayState) -> String {
        if let notice = model.liveNotice { return notice }
        if live.phase != .recording {
            return live.stoppedAtLimit
                ? L10n.string("live.limit.reached", fallback: "Recording limit reached · recording stopped")
                : L10n.string("live.stopped", fallback: "Recording stopped")
        }
        return live.elapsed >= 50
            ? L10n.format("live.countdown", "%1$d s left", arguments: [Int32(max(0, 60 - Int(live.elapsed)))])
            : L10n.string("live.release", fallback: "Release to finalize · Experimental")
    }

    private func liveLabel(_ phase: LiveDictationPhase) -> String {
        switch phase {
        case .recording: return L10n.string("live.name", fallback: "Local Live")
        case .polishing: return L10n.string("overlay.polishing", fallback: "Polishing…")
        case .draining: return L10n.string("live.cancelling", fallback: "Cancelling…")
        default: return L10n.string("live.finalizing", fallback: "Finalizing…")
        }
    }

    private var ordinaryContent: some View {
        Group {
            if case .notice(let message, _) = model.state {
                noticeContent(message: message)
            } else {
                activityContent
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: FloatingOverlayGeometry.progressWidth)
        .background(VisualEffectBlur(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(strokeColor, lineWidth: strokeWidth)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        .fixedSize()
    }

    /// Routine Listening / Transcribing / Polishing pill.
    private var activityContent: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: labelWidth, alignment: .leading)

            Spacer(minLength: 0)

            ZStack {
                switch model.state {
                case .recording(let level, _):
                    AudioBarsView(level: level)
                        .transition(.opacity)
                case .transcribing:
                    // Pulsing ellipsis — each dot fades in/out independently.
                    // More visually distinct from the 5 bars than a tiny
                    // ProgressView spinner, and the symbol effect handles
                    // the animation reliably inside an NSHostingView.
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .symbolEffect(.pulse.byLayer, options: .repeating)
                        .transition(.opacity)
                case .polishing:
                    ProgressView()
                        .controlSize(.small)
                case .hidden, .notice:
                    EmptyView()
                }
            }
            .frame(width: 40, height: 24)
            .animation(.easeInOut(duration: 0.18), value: stateKey)
        }
    }

    /// Failure notice. Deliberately has no activity slot: no bars, ellipsis or
    /// spinner, because nothing is being captured.
    private func noticeContent(message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.isShowingFailureNotice ? Color.orange : Color.primary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(noticeHeading)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Colour is never the only signal: the heading names the failure.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(noticeHeading). \(message)")
    }

    private var noticeHeading: String {
        if case .notice(_, .information(let heading)) = model.state { return heading }
        return L10n.string(
            "alert.dictation.capture_failed.title",
            fallback: "Could not record audio"
        )
    }

    private var strokeColor: Color {
        model.isShowingFailureNotice ? Color.orange.opacity(0.55) : Color.primary.opacity(0.08)
    }

    private var strokeWidth: CGFloat {
        model.isShowingFailureNotice ? 1 : 0.5
    }

    private var label: String {
        switch model.state {
        case .recording:
            return L10n.string("overlay.listening", fallback: "Listening")
        case .transcribing(let provider):
            if let provider {
                return L10n.format(
                    "overlay.transcribing_provider",
                    "Transcribing · %1$@",
                    arguments: [provider]
                )
            }
            return L10n.string("overlay.transcribing", fallback: "Transcribing")
        case .polishing:
            return L10n.string("overlay.polishing", fallback: "Polishing…")
        case .notice(let message, _):
            return message
        case .hidden:
            return ""
        }
    }

    private var iconName: String {
        switch model.state {
        case .polishing: return "wand.and.sparkles"
        case .notice:    return model.isShowingFailureNotice ? "exclamationmark.triangle.fill" : "info.circle.fill"
        default:         return "mic.fill"
        }
    }

    private var labelWidth: CGFloat {
        // The panel sizes itself when recording begins and does not resize on
        // the later state swap. Cloud recording reserves provider-label width
        // up front; local recording/transcription keeps the original 80 pt.
        switch model.state {
        case .recording(_, let provider), .transcribing(let provider):
            return provider == nil ? 80 : 150
        case .notice:
            // Wrapping width for the two-line notice. With the icon and the
            // 18 pt side padding this keeps the pill under about 400 pt.
            return 320
        default:
            return 80
        }
    }

    /// Stable key for animating the ZStack content swap (don't animate on
    /// every RMS level change, only on state-class change).
    private var stateKey: Int {
        switch model.state {
        case .hidden:        return 0
        case .recording:     return 1
        case .transcribing:  return 2
        case .polishing:     return 3
        case .notice:        return 4
        }
    }
}

// MARK: - Audio bars (5 vertical capsules driven by RMS)

private struct AudioBarsView: View {
    let level: Float

    private let barCount = 5
    private let maxHeight: CGFloat = 22

    /// Per-bar weight — center bars peak slightly taller for a "voice" curve.
    private let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.85, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 3, height: barHeight(index: i))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: maxHeight)
    }

    private func barHeight(index: Int) -> CGFloat {
        // Speech RMS is empirically much smaller than I assumed — typical
        // values are 0.005-0.05 for normal voice. Use a square-root mapping
        // with high boost so soft speech reaches mid-range and normal speech
        // saturates the bars.
        let boosted = min(1.0, CGFloat(level) * 30.0)
        let curved = sqrt(boosted)  // sqrt gives more visual range to soft speech
        let scaled = curved * weights[index]
        return max(3, maxHeight * scaled)
    }
}
