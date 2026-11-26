import Foundation

/// Admission is cheap inside the event tap. All capture/reload work runs later
/// on main, and every duration is measured from the original physical key down.
@MainActor
final class DictationPressAdmission {
    static let soloDelay: TimeInterval = 0.15
    static let reloadThreshold: TimeInterval = 0.3
    private static let secureNoticeThreshold: TimeInterval = 0.8
    enum Release: Equatable { case none, tap, started, ignoredHold, cancelled }

    private final class Press {
        let began: TimeInterval
        let key: ShortcutChord
        let needsReload: () -> Bool
        let isCancelled: () -> Bool
        let start: (TimeInterval) -> Void
        let onAdmissionCheck: (Bool) -> Void
        var secureBlocked = false
        var started = false
        var work: DispatchWorkItem?
        init(began: TimeInterval, key: ShortcutChord, isCancelled: @escaping () -> Bool, needsReload: @escaping () -> Bool,
             onAdmissionCheck: @escaping (Bool) -> Void, start: @escaping (TimeInterval) -> Void) {
            self.began = began; self.key = key; self.needsReload = needsReload; self.start = start
            self.isCancelled = isCancelled
            self.onAdmissionCheck = onAdmissionCheck
        }
    }

    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private let secureInput: () -> Bool
    private let onSecureInputBlocked: (ShortcutChord) -> Void
    private var secureNoticeShown = false
    private var current: Press?
    private var releasedReload: DispatchWorkItem?
    private var generation = UUID()
    var isPending: Bool { current != nil && current?.started == false }

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = {
             if $0 == 0 {
                 DispatchQueue.main.async(execute: $1)
             } else {
                 DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
             }
         }, secureInput: @escaping () -> Bool = { SecureInputProbe.isActive() },
         onSecureInputBlocked: @escaping (ShortcutChord) -> Void = { _ in }) {
        self.now = now; self.schedule = schedule
        self.secureInput = secureInput; self.onSecureInputBlocked = onSecureInputBlocked
    }

    func press(key: ShortcutChord, began: TimeInterval? = nil,
               isCancelled: @escaping () -> Bool = { false },
               secureInputAtPress: Bool? = nil,
               onAdmissionCheck: @escaping (Bool) -> Void = { _ in },
               needsReload: @escaping () -> Bool, start: @escaping (TimeInterval) -> Void) {
        cancel()
        let press = Press(began: began ?? now(), key: key, isCancelled: isCancelled, needsReload: needsReload,
                          onAdmissionCheck: onAdmissionCheck, start: start)
        current = press
        let secure = secureInputAtPress ?? secureInput()
        if !secure { secureNoticeShown = false }
        guard !blockSecureInput(press, active: secure) else { return }
        guard !press.isCancelled() else { return }
        enqueue(press)
    }

    private func enqueue(_ press: Press) {
        let soloDelay = press.key == .rightOption ? 0 : Self.soloDelay
        let threshold = press.needsReload() ? Self.reloadThreshold : soloDelay
        let remaining = max(0, threshold - (now() - press.began))
        let work = DispatchWorkItem { [weak self, weak press] in
            MainActor.assumeIsolated {
                guard let self, let press, self.current === press, !press.started else { return }
                guard !press.isCancelled() else { return }
                let required = press.needsReload() ? Self.reloadThreshold : (press.key == .rightOption ? 0 : Self.soloDelay)
                guard self.now() - press.began >= required else { self.enqueue(press); return }
                let secure = self.secureInput()
                press.onAdmissionCheck(secure)
                guard !self.blockSecureInput(press, active: secure) else { return }
                press.started = true
                press.start(press.began)
            }
        }
        press.work = work
        schedule(remaining, work)
    }

    func release() -> Release {
        guard let press = current else { return .none }
        current = nil
        press.work?.cancel()
        if press.secureBlocked {
            if !press.isCancelled() { secureInputIgnored(key: press.key, began: press.began) }
            return .ignoredHold
        }
        if press.isCancelled() { return .cancelled }
        if press.started { return .started }
        let held = now() - press.began
        if held < Self.reloadThreshold { return .tap }
        // A queued timer may lose the race to a clean release. A confirmed
        // unloaded hold may still reload, but never open a mic after release.
        if press.needsReload() {
            let ticket = generation
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == ticket, !press.isCancelled(), press.needsReload() else { return }
                    self.releasedReload = nil
                    let secure = self.secureInput()
                    press.onAdmissionCheck(secure)
                    guard !self.blockSecureInput(press, active: secure) else {
                        self.notifyIfLongSecureHold(key: press.key, held: held)
                        return
                    }
                    press.start(press.began)
                }
            }
            releasedReload = work
            schedule(0, work)
        }
        return .ignoredHold
    }

    private func blockSecureInput(_ press: Press, active: Bool) -> Bool {
        guard press.key != .rightOption, active else { return press.secureBlocked }
        press.secureBlocked = true
        return true
    }

    /// Also used for a physical secure press that the event tap passed through.
    /// A short shortcut must neither show nor consume this episode's notice.
    func secureInputIgnored(key: ShortcutChord, began: TimeInterval) {
        notifyIfLongSecureHold(key: key, held: now() - began)
    }

    private func notifyIfLongSecureHold(key: ShortcutChord, held: TimeInterval) {
        guard key != .rightOption, held >= Self.secureNoticeThreshold,
              !secureNoticeShown else { return }
        secureNoticeShown = true
        onSecureInputBlocked(key)
    }

    func cancel() {
        generation = UUID()
        current?.work?.cancel(); current = nil
        releasedReload?.cancel(); releasedReload = nil
    }
}
