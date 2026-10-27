import Foundation

/// Delay only first-use consent, never an already-confirmed live recording.
/// Short taps/chords keep their existing meaning without microphone capture.
@MainActor
final class DefaultLiveHoldGate {
    static let threshold: TimeInterval = 0.3
    enum Release: Equatable { case none, tap, consumedHold }
    @MainActor private final class Pending {
        let began: TimeInterval
        let onHold: @MainActor (TimeInterval) -> Void
        var work: DispatchWorkItem!
        init(began: TimeInterval, onHold: @escaping @MainActor (TimeInterval) -> Void) {
            self.began = began; self.onHold = onHold
        }
    }
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private var pending: Pending?
    var isPending: Bool { pending != nil }

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         }) { self.now = now; self.schedule = schedule }

    func press(onHold: @escaping @MainActor (TimeInterval) -> Void) {
        cancel()
        let ticket = Pending(began: now(), onHold: onHold)
        pending = ticket
        enqueue(ticket, after: Self.threshold)
    }
    private func enqueue(_ ticket: Pending, after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self, weak ticket] in
            MainActor.assumeIsolated {
                guard let self, let ticket, self.pending === ticket, !ticket.work.isCancelled else { return }
                let remaining = Self.threshold - (self.now() - ticket.began)
                guard remaining <= 0 else { self.enqueue(ticket, after: remaining); return }
                self.pending = nil
                ticket.onHold(ticket.began)
            }
        }
        ticket.work = work; schedule(delay, work)
    }
    func release() -> Release {
        guard let ticket = pending else { return .none }
        pending = nil; ticket.work.cancel()
        if now() - ticket.began < Self.threshold { return .tap }
        ticket.onHold(ticket.began)
        return .consumedHold
    }
    @discardableResult func cancel() -> Bool {
        guard let ticket = pending else { return false }
        pending = nil; ticket.work.cancel(); return true
    }
}
