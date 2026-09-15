import SwiftUI
import AppKit

// MARK: - State

/// Visible state of the floating overlay. The window itself is shown/hidden
/// independently — `.hidden` is here only for clarity, in practice the window
/// is ordered out instead of rendering this case.
enum OverlayState: Equatable {
    case hidden
    case recording(level: Float, provider: String?)  // 0.0–1.0 RMS
    case transcribing(provider: String?)
    case polishing
    /// Brief non-modal failure notice. The payload is already-localized plain
    /// text, never a localization key and never Markdown.
    case notice(message: String)
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
final class OverlayStateModel: ObservableObject {
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

    /// True while a failure notice is the visible state.
    var isShowingNotice: Bool {
        if case .notice = state { return true }
        return false
    }

    /// Show `message` as a notice and take ownership of it, replacing any
    /// notice already on screen.
    @discardableResult
    func beginNotice(message: String) -> NoticeTicket {
        let ticket = NoticeTicket()
        state = .notice(message: message)
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

struct FloatingOverlayView: View {
    @ObservedObject var model: OverlayStateModel

    var body: some View {
        Group {
            if case .notice(let message) = model.state {
                noticeContent(message: message)
            } else {
                activityContent
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(VisualEffectBlur(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(strokeColor, lineWidth: strokeWidth)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        .fixedSize()
    }

    /// Routine Listening / Transcribing / Polishing pill, unchanged.
    private var activityContent: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: labelWidth, alignment: .leading)

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
                .foregroundStyle(Color.orange)
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
            .frame(width: labelWidth, alignment: .leading)
        }
        // Colour is never the only signal: the heading names the failure.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(noticeHeading). \(message)")
    }

    private var noticeHeading: String {
        L10n.string(
            "alert.dictation.capture_failed.title",
            fallback: "Could not record audio"
        )
    }

    private var strokeColor: Color {
        model.isShowingNotice ? Color.orange.opacity(0.55) : Color.primary.opacity(0.08)
    }

    private var strokeWidth: CGFloat {
        model.isShowingNotice ? 1 : 0.5
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
        case .notice(let message):
            return message
        case .hidden:
            return ""
        }
    }

    private var iconName: String {
        switch model.state {
        case .polishing: return "wand.and.sparkles"
        case .notice:    return "exclamationmark.triangle.fill"
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
