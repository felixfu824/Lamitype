import AppKit
import XCTest
@testable import HushType

@MainActor
final class DictationPressAdmissionTests: XCTestCase {
    private final class Clock {
        var time: TimeInterval = 0
        var jobs: [(TimeInterval, DispatchWorkItem)] = []
        var captures = 0
        var reloads = 0
        var unloaded = false
        var origins: [TimeInterval] = []
    }
    private func make(_ c: Clock) -> DictationPressAdmission {
        DictationPressAdmission(now: { c.time }, schedule: { c.jobs.append(($0, $1)) }, secureInput: { false })
    }
    private func press(_ gate: DictationPressAdmission, _ c: Clock, key: DictationKey) {
        gate.press(key: key.chord, needsReload: { c.unloaded }, start: { began in
            c.origins.append(began)
            if c.unloaded { c.reloads += 1 } else { c.captures += 1 }
        })
    }
    private func modifier(_ key: DictationKey, down: Bool) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: down)!
        event.flags = down ? CGEventFlags(rawValue: key.deviceBit) : []
        return event
    }

    func testSecureInputAtPressBlocksTapsHoldsReloadsAndNoticesOnlyOnLongRelease() {
        let c = Clock()
        var secure = true, notices: [ShortcutChord] = [], taps = 0
        let gate = DictationPressAdmission(now: { c.time }, schedule: { c.jobs.append(($0, $1)) },
            secureInput: { secure }, onSecureInputBlocked: { notices.append($0) })
        for key in [DictationKey.rightCommand, .rightControl] {
            for unloaded in [false, true] {
                for elapsed in [0.05, 1.0] {
                    c.unloaded = unloaded
                    press(gate, c, key: key)
                    // Once blocked, clearing Secure Input cannot revive this press.
                    secure = false
                    c.time += elapsed
                    for (_, job) in c.jobs { job.perform() }
                    let release = gate.release()
                    XCTAssertEqual(release, .ignoredHold)
                    if release == .tap { taps += 1 }
                    secure = true
                }
            }
        }
        XCTAssertEqual(notices, [.rightCommand])
        XCTAssertEqual(c.captures, 0); XCTAssertEqual(c.reloads, 0); XCTAssertEqual(taps, 0)
        XCTAssertTrue(c.jobs.isEmpty)
    }

    func testSecureInputBecomingActiveAtAdmissionBlocksCaptureAndReload() {
        for key in [DictationKey.rightCommand, .rightControl] {
            for unloaded in [false, true] {
                let c = Clock()
                c.unloaded = unloaded
                var secure = false, notices = 0, checks: [Bool] = []
                let gate = DictationPressAdmission(now: { c.time }, schedule: { c.jobs.append(($0, $1)) },
                    secureInput: { secure }, onSecureInputBlocked: { _ in notices += 1 })
                gate.press(key: key.chord, onAdmissionCheck: { checks.append($0) }, needsReload: { unloaded },
                           start: { _ in if unloaded { c.reloads += 1 } else { c.captures += 1 } })
                secure = true
                c.time = unloaded ? 0.3 : 0.15
                c.jobs[0].1.perform()
                XCTAssertEqual(checks, [true]); XCTAssertEqual(notices, 0)
                secure = false
                c.jobs[0].1.perform()
                c.time = 1.0
                XCTAssertEqual(gate.release(), .ignoredHold)
                XCTAssertEqual(notices, 1)
                XCTAssertEqual(c.captures, 0); XCTAssertEqual(c.reloads, 0)
            }
        }
    }

    func testChordAfterSecureAdmissionDoesNotNotifyOrConsumeEpisodeNotice() {
        let c = Clock()
        var secure = false, chord = false, notices = 0
        let gate = DictationPressAdmission(now: { c.time }, schedule: { c.jobs.append(($0, $1)) },
            secureInput: { secure }, onSecureInputBlocked: { _ in notices += 1 })
        gate.press(key: .rightCommand, isCancelled: { chord }, needsReload: { false },
                   start: { _ in XCTFail("Blocked admission started") })
        secure = true
        c.time = 0.15
        c.jobs[0].1.perform()
        chord = true
        c.time = 1.0
        XCTAssertEqual(gate.release(), .ignoredHold)
        XCTAssertEqual(notices, 0)
        press(gate, c, key: .rightCommand)
        c.time = 2.0
        XCTAssertEqual(gate.release(), .ignoredHold)
        XCTAssertEqual(notices, 1)
    }

    func testPhysicalSecureSampleCannotBeLostBeforeAdmissionCreation() {
        let c = Clock()
        var notices = 0
        let gate = DictationPressAdmission(now: { c.time }, schedule: { c.jobs.append(($0, $1)) },
            secureInput: { false }, onSecureInputBlocked: { _ in notices += 1 })
        gate.press(key: .rightCommand, began: 0, secureInputAtPress: true,
                   needsReload: { false }, start: { _ in c.captures += 1 })
        XCTAssertEqual(notices, 0)
        c.time = 1.0
        XCTAssertEqual(gate.release(), .ignoredHold)
        XCTAssertTrue(c.jobs.isEmpty)
        XCTAssertEqual(c.captures, 0); XCTAssertEqual(notices, 1)
    }

    func testSecureNoticeRequiresLongReleaseAndResetsOnlyAfterSecureOffPress() {
        for key in [DictationKey.rightCommand, .rightControl] {
            let c = Clock()
            var secure = true, notices = 0
            let gate = DictationPressAdmission(now: { c.time }, schedule: { c.jobs.append(($0, $1)) },
                secureInput: { secure }, onSecureInputBlocked: { _ in notices += 1 })
            for elapsed in [0.1, 0.5, 1.0, 1.0] {
                press(gate, c, key: key)
                let before = notices
                c.time += elapsed
                XCTAssertEqual(notices, before, "No notice at down or while held")
                XCTAssertEqual(gate.release(), .ignoredHold)
                XCTAssertEqual(notices, elapsed < 0.8 ? 0 : 1)
            }
            secure = false
            press(gate, c, key: key)
            c.time += 0.1
            XCTAssertEqual(gate.release(), .tap)
            secure = true
            press(gate, c, key: key)
            c.time += 1.0
            XCTAssertEqual(notices, 1)
            XCTAssertEqual(gate.release(), .ignoredHold)
            XCTAssertEqual(notices, 2)
            XCTAssertEqual(c.captures, 0); XCTAssertEqual(c.reloads, 0)
        }
    }

    func testTurningSecureInputOffRestoresNormalHoldReloadAndTap() {
        for key in [DictationKey.rightCommand, .rightControl] {
            for unloaded in [false, true] {
                let c = Clock()
                c.unloaded = unloaded
                var secure = true
                let gate = DictationPressAdmission(now: { c.time }, schedule: { c.jobs.append(($0, $1)) },
                    secureInput: { secure })
                press(gate, c, key: key)
                XCTAssertEqual(gate.release(), .ignoredHold)
                secure = false
                press(gate, c, key: key)
                c.time = unloaded ? 0.3 : 0.15
                c.jobs.last!.1.perform()
                XCTAssertEqual(gate.release(), .started)
                XCTAssertEqual(c.captures, unloaded ? 0 : 1); XCTAssertEqual(c.reloads, unloaded ? 1 : 0)
                press(gate, c, key: key)
                c.time += 0.05
                XCTAssertEqual(gate.release(), .tap)
            }
        }
    }

    func testPassedThroughSecureHoldsShareEpisodeNoticeWithAdmissionGuard() {
        let c = Clock()
        var notices = 0
        let gate = DictationPressAdmission(now: { c.time }, schedule: { c.jobs.append(($0, $1)) },
            secureInput: { false }, onSecureInputBlocked: { _ in notices += 1 })
        c.time = 0.1
        gate.secureInputIgnored(key: .rightCommand, began: 0)
        XCTAssertEqual(notices, 0)
        c.time = 0.5
        gate.secureInputIgnored(key: .rightCommand, began: 0)
        XCTAssertEqual(notices, 0)
        c.time = 1.0
        gate.secureInputIgnored(key: .rightCommand, began: 0)
        gate.secureInputIgnored(key: .rightControl, began: 0)
        XCTAssertEqual(notices, 1)
        press(gate, c, key: .rightControl) // A physical secure-off press resets the episode.
        c.time += 0.1
        XCTAssertEqual(gate.release(), .tap)
        c.time += 1.0
        gate.secureInputIgnored(key: .rightControl, began: 1.1)
        XCTAssertEqual(notices, 2)
        XCTAssertEqual(gate.release(), .none, "Pass-through never creates admission work")
        gate.secureInputIgnored(key: .rightOption, began: 0)
        XCTAssertEqual(notices, 2)
    }

    func testReleasedReloadRechecksSecureInputBeforeStarting() {
        for key in [DictationKey.rightCommand, .rightControl] {
            let c = Clock()
            c.unloaded = true
            var secure = false, notices = 0
            let gate = DictationPressAdmission(now: { c.time }, schedule: { c.jobs.append(($0, $1)) },
                secureInput: { secure }, onSecureInputBlocked: { _ in notices += 1 })
            press(gate, c, key: key)
            c.time = 0.31
            XCTAssertEqual(gate.release(), .ignoredHold)
            secure = true
            c.time = 1.5 // Queue delay after release is not part of the hold.
            c.jobs.last!.1.perform()
            XCTAssertEqual(c.reloads, 0); XCTAssertEqual(c.captures, 0); XCTAssertEqual(notices, 0)
        }
    }

    func testOptionAdmissionAndTapsRemainUnchangedWithSecureInputActive() {
        for unloaded in [false, true] {
            let c = Clock()
            c.unloaded = unloaded
            var notices = 0
            let gate = DictationPressAdmission(now: { c.time }, schedule: { c.jobs.append(($0, $1)) },
                secureInput: { true }, onSecureInputBlocked: { _ in notices += 1 })
            press(gate, c, key: .rightOption)
            XCTAssertEqual(c.jobs[0].0, unloaded ? 0.3 : 0)
            c.time = unloaded ? 0.3 : 0
            c.jobs[0].1.perform()
            XCTAssertEqual(gate.release(), .started)
            XCTAssertEqual(c.captures, unloaded ? 0 : 1); XCTAssertEqual(c.reloads, unloaded ? 1 : 0)
            c.unloaded = true
            press(gate, c, key: .rightOption)
            c.time += 0.05
            XCTAssertEqual(gate.release(), .tap)
            XCTAssertEqual(notices, 0)
        }
    }

    func testChordBeforeQueuedPressWorkCannotBeForgotten() {
        assertChordOrdering(beforePressWork: true)
    }

    func testChordBetweenPressWorkAndTimerBlocksAdmissionWithoutCancellationCallback() {
        assertChordOrdering(beforePressWork: false)
    }

    private func assertChordOrdering(beforePressWork: Bool) {
        for key in [DictationKey.rightCommand, .rightControl] {
            for unloaded in [false, true] {
                let c = Clock(), gate = make(c)
                c.unloaded = unloaded
                let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off), secureInput: { false })
                var queuedPress: (() -> Void)?
                var cancellations = 0, releases = 0, taps = 0
                manager.onPress = {
                    let press = manager.currentPress!
                    let began = c.time
                    queuedPress = {
                        gate.press(key: press.key, began: began, isCancelled: { press.isCancelled },
                                   needsReload: { c.unloaded }, start: { _ in
                            if c.unloaded { c.reloads += 1 } else { c.captures += 1 }
                        })
                    }
                }
                manager.onChordDuringHold = {
                    // Cancel before creation, or deliberately delay this callback's
                    // work until after the timer: the press record must suffice.
                    if beforePressWork { gate.cancel() }
                }
                manager.onCancelledRelease = { _ in
                    cancellations += 1
                    XCTAssertEqual(gate.release(), .cancelled)
                    gate.cancel()
                }
                manager.onRelease = {
                    releases += 1
                    if gate.release() == .tap { taps += 1 }
                }
                _ = manager.handleEvent(type: .flagsChanged, event: modifier(key, down: true))
                if !beforePressWork { queuedPress!() }
                c.time = 0.05
                let copy = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)!
                copy.flags = CGEventFlags(rawValue: key.deviceBit | (key == .rightCommand
                    ? CGEventFlags.maskCommand.rawValue : CGEventFlags.maskControl.rawValue))
                _ = manager.handleEvent(type: .keyDown, event: copy)
                _ = manager.handleEvent(type: .keyUp, event: copy)
                if beforePressWork { queuedPress!() }
                c.time = unloaded ? 0.31 : 0.16
                for (_, job) in c.jobs { job.perform() }
                XCTAssertEqual(c.captures, 0); XCTAssertEqual(c.reloads, 0)
                let releaseEvent = modifier(key, down: false)
                XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: releaseEvent)?.takeUnretainedValue() === releaseEvent)
                // Duplicate release and stale admission work cannot dispatch again.
                _ = manager.handleEvent(type: .flagsChanged, event: modifier(key, down: false))
                c.time = 1
                for (_, job) in c.jobs { job.perform() }
                XCTAssertEqual(c.captures, 0); XCTAssertEqual(c.reloads, 0)
                XCTAssertEqual(cancellations, 1)
                XCTAssertEqual(releases, 0); XCTAssertEqual(taps, 0)
            }
        }
    }

    func testCancelledPressRecordSurvivesReleaseAndNextPress() {
        let c = Clock(), gate = make(c)
        let manager = HotkeyManager(bindings: .init(dictation: .rightCommand, liveCaption: .off), secureInput: { false })
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(.rightCommand, down: true))
        let oldPress = manager.currentPress!
        let copy = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)!
        _ = manager.handleEvent(type: .keyDown, event: copy)
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(.rightCommand, down: false))
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(.rightCommand, down: true))
        XCTAssertFalse(manager.currentPress === oldPress)
        XCTAssertFalse(manager.currentPress!.isCancelled)
        gate.press(key: oldPress.key, isCancelled: { oldPress.isCancelled },
                   needsReload: { true }, start: { _ in c.reloads += 1 })
        XCTAssertTrue(c.jobs.isEmpty)
        XCTAssertEqual(gate.release(), .cancelled)
        XCTAssertEqual(c.reloads, 0)
    }

    func testReleasedReloadRechecksCancellationBeforeStarting() {
        let c = Clock(), gate = make(c)
        var cancelled = false
        gate.press(key: .rightCommand, isCancelled: { cancelled },
                   needsReload: { true }, start: { _ in c.reloads += 1 })
        c.time = 0.31
        XCTAssertEqual(gate.release(), .ignoredHold)
        cancelled = true
        c.jobs.last!.1.perform()
        XCTAssertEqual(c.reloads, 0)
    }

    func testCommandAndControlChordWithinDeferralStartsNeitherCaptureNorReload() {
        for key in [DictationKey.rightCommand, .rightControl] {
            for unloaded in [false, true] {
                let c = Clock(), gate = make(c)
                c.unloaded = unloaded
                let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off), secureInput: { false })
                manager.onPress = { self.press(gate, c, key: key) }
                manager.onChordDuringHold = { gate.cancel() }
                manager.onCancelledRelease = { _ in gate.cancel() }
                _ = manager.handleEvent(type: .flagsChanged, event: modifier(key, down: true))
                c.time = 0.08
                let copy = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)!
                _ = manager.handleEvent(type: .keyDown, event: copy)
                _ = manager.handleEvent(type: .flagsChanged, event: modifier(key, down: false))
                c.time = 1
                for (_, job) in c.jobs { job.perform() }
                XCTAssertEqual(c.captures, 0); XCTAssertEqual(c.reloads, 0)
            }
        }
    }

    func testModifierChordsAndPreheldModifiersAreNotSoloHolds() {
        for preheld in [false, true] {
            let c = Clock(), gate = make(c)
            let manager = HotkeyManager(bindings: .init(dictation: .rightCommand, liveCaption: .off), secureInput: { false })
            manager.onPress = {
                XCTAssertEqual(manager.currentPress?.isCancelled, preheld)
                self.press(gate, c, key: .rightCommand)
            }
            manager.onChordDuringHold = { gate.cancel() }
            let down = modifier(.rightCommand, down: true)
            if preheld { down.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue | 0x10) }
            _ = manager.handleEvent(type: .flagsChanged, event: down)
            if !preheld {
                c.time = 0.1
                let shift = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true)!
                shift.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue | 0x10 | 0x02)
                _ = manager.handleEvent(type: .flagsChanged, event: shift)
            }
            c.time = 0.2
            for (_, work) in c.jobs { work.perform() }
            XCTAssertEqual(c.captures, 0); XCTAssertEqual(c.reloads, 0)
        }
    }

    func testSoloHoldStartsAfter150msAndKeepsPhysicalKeyDownOrigin() {
        for key in [DictationKey.rightCommand, .rightControl] {
            let c = Clock(), gate = make(c)
            press(gate, c, key: key)
            XCTAssertEqual(c.jobs[0].0, 0.15, accuracy: 0.00001)
            c.time = 0.1; c.jobs[0].1.perform()
            XCTAssertEqual(c.captures, 0)
            c.time = 0.15; c.jobs[1].1.perform()
            XCTAssertEqual(c.captures, 1); XCTAssertEqual(c.origins, [0])
            c.time = 0.25
            XCTAssertEqual(gate.release(), .started)
            XCTAssertTrue(isTranslationTap(elapsed: c.time - c.origins[0], captureFailed: false))
        }
    }

    func testQuickTapAndDoubleTapHaveNoCaptureAndKeepTapArbiterSemantics() {
        let c = Clock(), gate = make(c), arbiter = TapArbiter()
        defer { arbiter.reset() }
        press(gate, c, key: .rightCommand)
        c.time = 0.1
        XCTAssertEqual(gate.release(), .tap)
        var singleTaps = 0
        arbiter.deferSingleTap { singleTaps += 1 }
        c.time = 0.4 // Before tap #1's 0.35-second decision window ends.
        XCTAssertTrue(arbiter.cancelPendingForSecondPress())
        press(gate, c, key: .rightCommand)
        c.time = 0.5
        XCTAssertEqual(gate.release(), .tap)
        XCTAssertTrue(arbiter.consumeSecondTapCandidate())
        c.time = 1
        for (_, job) in c.jobs { job.perform() }
        XCTAssertEqual(singleTaps, 0)
        XCTAssertEqual(c.captures, 0); XCTAssertEqual(c.reloads, 0)
    }

    func testOptionHasNoAddedSoloDelayButItsWorkIsQueuedOutsideCallback() {
        let c = Clock(), gate = make(c)
        press(gate, c, key: .rightOption)
        XCTAssertEqual(c.captures, 0)
        XCTAssertEqual(c.jobs[0].0, 0)
        c.jobs[0].1.perform()
        XCTAssertEqual(c.captures, 1)
        XCTAssertEqual(gate.release(), .started)
    }

    func testEveryUnloadedBindingWaitsForCleanHoldAndChordPreventsReload() {
        for key in DictationKey.allCases {
            let c = Clock(), gate = make(c)
            c.unloaded = true
            press(gate, c, key: key)
            XCTAssertEqual(c.jobs[0].0, 0.3, accuracy: 0.00001)
            c.time = 0.15; c.jobs[0].1.perform()
            XCTAssertEqual(c.reloads, 0)
            gate.cancel()
            c.time = 1; c.jobs[1].1.perform()
            XCTAssertEqual(c.reloads, 0)
            press(gate, c, key: key)
            c.time = 1.3; c.jobs.last!.1.perform()
            XCTAssertEqual(c.reloads, 1); XCTAssertEqual(c.captures, 0)
        }
    }

    func testCleanReleasedUnloadedHoldCanReloadButNeverOpensMicAfterRelease() {
        let c = Clock(), gate = make(c)
        c.unloaded = true
        press(gate, c, key: .rightCommand)
        c.time = 0.31
        XCTAssertEqual(gate.release(), .ignoredHold)
        XCTAssertEqual(c.reloads, 0)
        c.jobs.last!.1.perform()
        XCTAssertEqual(c.reloads, 1); XCTAssertEqual(c.captures, 0)
        c.unloaded = false
        press(gate, c, key: .rightCommand)
        c.time = 0.7
        XCTAssertEqual(gate.release(), .ignoredHold)
        for (_, job) in c.jobs { job.perform() }
        XCTAssertEqual(c.captures, 0)
    }

    func testCancelledAdmissionCannotStartAfterRebindOrInterruption() {
        let c = Clock(), gate = make(c)
        press(gate, c, key: .rightCommand)
        XCTAssertTrue(gate.isPending)
        gate.cancel()
        c.time = 0.2
        c.jobs[0].1.perform()
        XCTAssertFalse(gate.isPending)
        XCTAssertEqual(gate.release(), .none)
        XCTAssertEqual(c.captures, 0)
    }
}
