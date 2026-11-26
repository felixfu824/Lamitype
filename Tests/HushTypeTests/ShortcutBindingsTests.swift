import AppKit
import AVFoundation
import XCTest
@testable import HushType

private final class ShortcutObservedDefaults: UserDefaults, @unchecked Sendable {
    var afterWrite: ((String) -> Void)?

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        afterWrite?(defaultName)
    }
}

private final class ChordCaptureDriver: CaptureDriver {
    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    var stops = 0
    var feed: ((AVAudioPCMBuffer) -> Void)?
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onConfigurationChange: @escaping () -> Void) throws { feed = onBuffer }
    func emit(_ count: Int) {
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count { buffer.floatChannelData![0][index] = 0.1 }
        feed?(buffer)
    }
    func stop() { stops += 1 }
}

@MainActor
final class ShortcutBindingsTests: XCTestCase {
    private func event(_ key: CGKeyCode, _ flags: UInt64 = 0, repeatKey: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
        event.flags = CGEventFlags(rawValue: flags)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }

    func testAllModifierSidesCloseOnceWhileOtherSideRemainsDown() {
        let cases: [(DictationKey, UInt64, UInt64, CGKeyCode)] = [
            (.rightOption, CGEventFlags.maskAlternate.rawValue, 0x20, 58),
            (.rightCommand, CGEventFlags.maskCommand.rawValue, 0x08, 55),
            (.rightControl, CGEventFlags.maskControl.rawValue, 0x01, 59),
        ]
        for (key, aggregate, left, leftCode) in cases {
            let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off), secureInput: { false })
            var presses = 0, releases = 0
            manager.onPress = { presses += 1 }; manager.onRelease = { releases += 1 }
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(key.keyCode, aggregate | key.deviceBit | left)) == nil)
            // The other side's release must not close this press.
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(leftCode, aggregate | key.deviceBit)) != nil)
            XCTAssertEqual(releases, 0)
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(key.keyCode, aggregate | left)) == nil)
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(key.keyCode, aggregate | left)) != nil)
            XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 1)
        }
    }

    func testCaptionMatchingIsExactAndIgnoresFnAndCapsLock() {
        let defaults = ShortcutBindings.default
        let cmd = CGEventFlags.maskCommand.rawValue
        XCTAssertEqual(defaults.classify(type: .keyDown, keyCode: 44, flags: .init(rawValue: cmd | 0x10)), .captionToggle)
        for flags: UInt64 in [cmd | 0x08, cmd | 0x18, cmd | 0x10 | CGEventFlags.maskShift.rawValue,
                               cmd | 0x10 | CGEventFlags.maskAlternate.rawValue,
                               cmd | 0x10 | CGEventFlags.maskControl.rawValue] {
            XCTAssertEqual(defaults.classify(type: .keyDown, keyCode: 44, flags: .init(rawValue: flags)), .passThrough)
        }
        XCTAssertEqual(defaults.classify(type: .keyDown, keyCode: 44,
            flags: .init(rawValue: cmd | 0x10 | CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskAlphaShift.rawValue)), .captionToggle)
        let alternate = ShortcutBindings(dictation: .rightCommand, liveCaption: .controlOptionSlash)
        XCTAssertEqual(alternate.classify(type: .keyDown, keyCode: 44, flags: [.maskControl, .maskAlternate]), .captionToggle)
        XCTAssertEqual(alternate.classify(type: .keyDown, keyCode: 44, flags: [.maskControl, .maskAlternate, .maskShift]), .passThrough)
        XCTAssertEqual(ShortcutBindings(dictation: .rightOption, liveCaption: .off).classify(type: .keyDown, keyCode: 44, flags: .init(rawValue: cmd | 0x10)), .passThrough)
    }

    func testControlOptionPresetUsesOppositeSideOfBoundDictationModifier() {
        let base = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        let cases: [(DictationKey, UInt64, UInt64)] = [(.rightOption, 0x20, 0x40), (.rightControl, 0x01, 0x2000)]
        for (key, required, wrong) in cases {
            let bindings = ShortcutBindings(dictation: key, liveCaption: .controlOptionSlash)
            XCTAssertFalse(bindings.hasConflict)
            XCTAssertEqual(bindings.classify(type: .keyDown, keyCode: 44, flags: .init(rawValue: base | required)), .captionToggle)
            XCTAssertEqual(bindings.classify(type: .keyDown, keyCode: 44, flags: .init(rawValue: base | wrong)), .passThrough)
            XCTAssertEqual(bindings.classify(type: .keyDown, keyCode: 44, flags: .init(rawValue: base)), .passThrough)
            XCTAssertEqual(bindings.classify(type: .keyDown, keyCode: 44, flags: .init(rawValue: base | required | CGEventFlags.maskShift.rawValue)), .passThrough)
        }
    }

    func testWatchdogAcceptsEitherHardwareOrCombinedSessionDownState() {
        for hardwareDown in [false, true] {
            var hid = hardwareDown, combined = !hardwareDown
            let manager = HotkeyManager(keyStateReader: { source, _ in source == .hidSystemState ? hid : combined },
                                        modifierFlags: { _ in 0 }, keyboardTapEnabled: { _ in false }, secureInput: { false })
            var cancellations = 0
            manager.onCancelledRelease = { _ in cancellations += 1 }
            _ = manager.handleEvent(type: .flagsChanged, event: event(61, 0x40))
            for _ in 0..<3 { manager.checkForLostRelease() }
            XCTAssertEqual(cancellations, 0)
            hid = false; combined = false
            manager.checkForLostRelease(); XCTAssertEqual(cancellations, 0)
            manager.checkForLostRelease(); XCTAssertEqual(cancellations, 1)
        }
    }

    func testCaptionFiresOnceAndSuppressesRepeatAndReleaseEvenAfterModifierRelease() {
        let manager = HotkeyManager(secureInput: { false }); var toggles = 0
        manager.onLiveCaptionToggle = { toggles += 1 }
        let flags = CGEventFlags.maskCommand.rawValue | 0x10
        XCTAssertTrue(manager.handleEvent(type: .keyDown, event: event(44, flags)) == nil)
        XCTAssertTrue(manager.handleEvent(type: .keyDown, event: event(44, flags, repeatKey: true)) == nil)
        XCTAssertTrue(manager.handleEvent(type: .keyDown, event: event(44, 0, repeatKey: true)) == nil)
        XCTAssertTrue(manager.handleEvent(type: .keyUp, event: event(44)) == nil)
        XCTAssertEqual(toggles, 1)
        XCTAssertTrue(manager.handleEvent(type: .keyUp, event: event(44)) != nil)
        XCTAssertTrue(manager.handleEvent(type: .keyDown, event: event(44, flags)) == nil)
        XCTAssertEqual(toggles, 2)
    }

    func testLostCaptionReleaseDoesNotSwallowFutureSlashTyping() {
        let manager = HotkeyManager(keyIsDown: { _ in false }, secureInput: { false })
        _ = manager.handleEvent(type: .keyDown, event: event(44, CGEventFlags.maskCommand.rawValue | 0x10))
        manager.checkForLostRelease()
        XCTAssertTrue(manager.handleEvent(type: .keyDown, event: event(44)) != nil)
    }

    func testKeyboardAndEveryMouseButtonCancelHeldGestureWithoutSuppressingChord() {
        for type: CGEventType in [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let manager = HotkeyManager(bindings: .init(dictation: .rightControl, liveCaption: .off), secureInput: { false })
            var releases = 0, cancellations = 0, chords = 0
            manager.onRelease = { releases += 1 }; manager.onCancelledRelease = { _ in cancellations += 1 }
            manager.onChordDuringHold = { chords += 1 }
            _ = manager.handleEvent(type: .flagsChanged, event: event(62, 0x2000))
            let chord = event(9, 0x2000)
            if type == .keyDown {
                XCTAssertTrue(manager.handleEvent(type: type, event: chord)?.takeUnretainedValue() === chord)
                _ = manager.handleEvent(type: type, event: chord)
            } else {
                XCTAssertTrue(manager.handleMouseEvent(type: type, event: chord).takeUnretainedValue() === chord)
                _ = manager.handleMouseEvent(type: type, event: chord)
            }
            _ = manager.handleEvent(type: .flagsChanged, event: event(62))
            XCTAssertEqual(releases, 0); XCTAssertEqual(cancellations, 1); XCTAssertEqual(chords, 1)
        }
    }

    func testFirstChordStopsCaptureAndOverlayBeforeReleaseExactlyOnce() throws {
        for key in [DictationKey.rightCommand, .rightControl] {
            let driver = ChordCaptureDriver()
            let capture = AudioCaptureService(makeDriver: { driver })
            let overlay = OverlayStateModel()
            let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off), secureInput: { false })
            let press = DictationPressRecord(keyDownUptime: 0)
            var state = AppDelegate.AppState.recording
            var liveCancellations = 0, cancelledReleases = 0, normalReleases = 0
            try capture.startRecording()
            overlay.state = .recording(level: 0, provider: nil)
            manager.onChordDuringHold = {
                state = cancelChordCapture(press: press, cancelCapture: { capture.cancelRecording(reason: .shortcutChord) },
                    cancelLive: { liveCancellations += 1 }, hideOverlay: { overlay.state = .hidden })
            }
            manager.onCancelledRelease = { _ in cancelledReleases += 1 }
            manager.onRelease = { normalReleases += 1 }
            _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode, key.deviceBit))
            XCTAssertTrue(manager.handleEvent(type: .keyDown, event: event(48)) != nil)
            XCTAssertTrue(state == .idle)
            XCTAssertEqual(overlay.state, .hidden)
            XCTAssertTrue(press.cancelled)
            XCTAssertFalse(press.claimErrorPresentation())
            XCTAssertEqual(driver.stops, 1)
            XCTAssertEqual(liveCancellations, 1)
            XCTAssertEqual(cancelledReleases, 0, "Physical release has not happened")
            XCTAssertTrue(manager.rightOptionIsDownForTesting, "Chord cancellation must preserve the physical latch")
            _ = manager.handleEvent(type: .keyDown, event: event(48))
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(key.keyCode)) != nil)
            XCTAssertEqual(cancelledReleases, 1)
            XCTAssertEqual(normalReleases, 0)
            XCTAssertEqual(driver.stops, 1)
            XCTAssertEqual(liveCancellations, 1)
        }
    }

    func testMouseClicksKeepDefaultOptionHoldButCancelCommandAndControl() {
        for key in DictationKey.allCases {
            for type: CGEventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
                let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off), secureInput: { false })
                var chords = 0, releases = 0, cancellations = 0
                manager.onChordDuringHold = { chords += 1 }
                manager.onRelease = { releases += 1 }
                manager.onCancelledRelease = { _ in cancellations += 1 }
                _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode, key.deviceBit))
                let click = event(0, key.deviceBit)
                XCTAssertTrue(manager.handleMouseEvent(type: type, event: click).takeUnretainedValue() === click)
                _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode))
                XCTAssertEqual(chords, key == .rightOption ? 0 : 1)
                XCTAssertEqual(releases, key == .rightOption ? 1 : 0)
                XCTAssertEqual(cancellations, key == .rightOption ? 0 : 1)
            }
        }
    }

    func testMouseClickWithoutSelectedDeviceBitDoesNotCancelJustReleasedHold() {
        for key in [DictationKey.rightCommand, .rightControl] {
            for type: CGEventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
                let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off), secureInput: { false })
                var chords = 0, releases = 0, cancellations = 0
                manager.onChordDuringHold = { chords += 1 }
                manager.onRelease = { releases += 1 }
                manager.onCancelledRelease = { _ in cancellations += 1 }
                _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode, key.deviceBit))
                // The mouse port wins scheduling after the physical modifier
                // release; aggregate flags alone do not mean this side is held.
                let click = event(0, CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue)
                XCTAssertTrue(manager.handleMouseEvent(type: type, event: click).takeUnretainedValue() === click)
                XCTAssertFalse(manager.currentPress!.isCancelled)
                _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode))
                XCTAssertEqual(chords, 0); XCTAssertEqual(cancellations, 0); XCTAssertEqual(releases, 1)
            }
        }
    }

    func testSecureCommandAndControlPassDownAndMatchingUpUnchangedWithoutLifecycle() {
        for key in [DictationKey.rightCommand, .rightControl] {
            var secure = true
            let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off), secureInput: { secure })
            var presses = 0, releases = 0, cancellations = 0, ignored = 0
            var releaseTime: TimeInterval = 0
            var notices: [ShortcutChord] = []
            let admission = DictationPressAdmission(now: { releaseTime }, secureInput: { secure },
                                                    onSecureInputBlocked: { notices.append($0) })
            manager.onPress = { presses += 1 }
            manager.onRelease = { releases += 1 }
            manager.onCancelledRelease = { _ in cancellations += 1 }
            manager.onSecureInputIgnored = { ignoredKey, began in
                XCTAssertEqual(ignoredKey, key.chord)
                XCTAssertLessThanOrEqual(began, ProcessInfo.processInfo.systemUptime)
                ignored += 1
                releaseTime = began + 1.0
                admission.secureInputIgnored(key: ignoredKey, began: began)
            }
            let down = event(key.keyCode, key.deviceBit)
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: down)?.takeUnretainedValue() === down)
            XCTAssertNil(manager.currentPress)
            XCTAssertFalse(manager.rightOptionIsDownForTesting)
            XCTAssertEqual(ignored, 0)
            // A later secure-off sample must not turn this matching up into dictation.
            secure = false
            let up = event(key.keyCode)
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: up)?.takeUnretainedValue() === up)
            XCTAssertEqual(presses, 0); XCTAssertEqual(releases, 0); XCTAssertEqual(cancellations, 0)
            XCTAssertEqual(ignored, 0)
            XCTAssertTrue(notices.isEmpty)
            XCTAssertNil(manager.currentPress)
            secure = true
            for _ in 0..<2 {
                XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: down)?.takeUnretainedValue() === down)
                XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: up)?.takeUnretainedValue() === up)
                XCTAssertEqual(notices, [key.chord], "Only the first one-second secure hold should notify")
            }
            secure = false
            XCTAssertNil(manager.handleEvent(type: .flagsChanged, event: down))
            XCTAssertEqual(presses, 1, "The next secure-off press resumes normal admission")
            XCTAssertNil(manager.handleEvent(type: .flagsChanged, event: up))
            XCTAssertEqual(releases, 1)
        }
    }

    func testSecureChordEvidenceSuppressesNoticeAndPassesEventsThrough() {
        for key in [DictationKey.rightCommand, .rightControl] {
            let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off), secureInput: { true })
            manager.onSecureInputIgnored = { _, _ in XCTFail("A visible chord must not notify") }
            manager.onChordDuringHold = { XCTFail("An ignored press has no dictation lifecycle") }
            for (type, code): (CGEventType, CGKeyCode) in [
                (.flagsChanged, 58), (.flagsChanged, 56), (.keyDown, 48), (.keyUp, 48),
                (.leftMouseDown, 0), (.rightMouseDown, 0), (.otherMouseDown, 0)
            ] {
                let down = event(key.keyCode, key.deviceBit)
                XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: down)?.takeUnretainedValue() === down)
                // Option down, Shift up, or a visible nonmodifier edge during the hold.
                let chord = event(code, key.deviceBit | (code == 58 ? 0x20 : 0))
                switch type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    XCTAssertTrue(manager.handleMouseEvent(type: type, event: chord).takeUnretainedValue() === chord)
                default:
                    XCTAssertTrue(manager.handleEvent(type: type, event: chord)?.takeUnretainedValue() === chord)
                }
                let up = event(key.keyCode)
                XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: up)?.takeUnretainedValue() === up)
            }
            let preheldShift = event(key.keyCode, key.deviceBit | CGEventFlags.maskShift.rawValue)
            _ = manager.handleEvent(type: .flagsChanged, event: preheldShift)
            _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode))
        }
    }

    func testSecureSoloHoldIgnoresTaggedCopiesOwnKeyUpAndClicksWithoutDeviceBit() {
        let key = DictationKey.rightCommand
        let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off), secureInput: { true })
        var soloReleases = 0
        manager.onSecureInputIgnored = { _, _ in soloReleases += 1 }
        _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode, key.deviceBit))
        let copy = event(8, CGEventFlags.maskCommand.rawValue)
        copy.setIntegerValueField(.eventSourceUserData, value: ShortcutBindings.syntheticEventTag)
        _ = manager.handleEvent(type: .keyDown, event: copy)
        _ = manager.handleEvent(type: .keyUp, event: copy)
        _ = manager.handleMouseEvent(type: .leftMouseDown, event: event(0, CGEventFlags.maskCommand.rawValue))
        _ = manager.handleEvent(type: .keyUp, event: event(key.keyCode))
        _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode))
        XCTAssertEqual(soloReleases, 1)
    }

    func testLostSecureReleaseRecoversAfterTwoConsecutiveUpReadingsWithoutNotice() {
        var secure = true, physicalDown = false, ignored = 0
        let key = DictationKey.rightCommand
        let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off),
            keyIsDown: { _ in physicalDown }, secureInput: { secure })
        manager.onSecureInputIgnored = { _, _ in ignored += 1 }
        manager.onCancelledRelease = { _ in XCTFail("Ignored presses never enter the dictation lifecycle") }
        let down = event(key.keyCode, key.deviceBit), up = event(key.keyCode)
        _ = manager.handleEvent(type: .flagsChanged, event: down)
        manager.checkForLostRelease()
        physicalDown = true
        manager.checkForLostRelease()
        physicalDown = false
        manager.checkForLostRelease()
        _ = manager.handleEvent(type: .flagsChanged, event: up)
        XCTAssertEqual(ignored, 1, "One up tick after a down still allows the real release")

        _ = manager.handleEvent(type: .flagsChanged, event: down)
        manager.checkForLostRelease()
        manager.checkForLostRelease()
        secure = false
        XCTAssertNotNil(manager.handleEvent(type: .flagsChanged, event: up))
        XCTAssertEqual(ignored, 1, "Neither retirement nor the late release may notify")
        XCTAssertNil(manager.handleEvent(type: .flagsChanged, event: down))
        XCTAssertNotNil(manager.currentPress, "The next secure-off down must start immediately")
        XCTAssertNil(manager.handleEvent(type: .flagsChanged, event: up))
    }

    func testSecureOptionKeepsSuppressionAndNormalPressReleaseCallbacks() {
        let manager = HotkeyManager(secureInput: { true })
        var presses = 0, releases = 0, ignored = 0, cancellations = 0
        manager.onPress = { presses += 1 }; manager.onRelease = { releases += 1 }
        manager.onCancelledRelease = { _ in cancellations += 1 }
        manager.onSecureInputIgnored = { _, _ in ignored += 1 }
        XCTAssertNil(manager.handleEvent(type: .flagsChanged, event: event(61, 0x40)))
        XCTAssertNotNil(manager.currentPress)
        XCTAssertNil(manager.handleEvent(type: .flagsChanged, event: event(61)))
        XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 1)
        XCTAssertEqual(ignored, 0); XCTAssertEqual(cancellations, 0)
    }

    func testPressDiagnosticCountsOnlyUntaggedKeyDownEventsAndKeepsSecureSamples() {
        var secure = true
        let manager = HotkeyManager(bindings: .init(dictation: .rightOption, liveCaption: .off), secureInput: { secure })
        _ = manager.handleEvent(type: .flagsChanged, event: event(61, 0x40))
        let press = manager.currentPress!
        XCTAssertTrue(press.secureInputAtPress)
        XCTAssertNil(press.secureInputAtAdmission)
        secure = false
        press.secureInputAtAdmission = secure
        _ = manager.handleEvent(type: .keyDown, event: event(8))
        _ = manager.handleEvent(type: .keyDown, event: event(9, repeatKey: true))
        _ = manager.handleEvent(type: .keyUp, event: event(9))
        let synthetic = event(8)
        synthetic.setIntegerValueField(.eventSourceUserData, value: ShortcutBindings.syntheticEventTag)
        _ = manager.handleEvent(type: .keyDown, event: synthetic)
        XCTAssertEqual(press.keyDownCount, 2)
        XCTAssertTrue(press.secureInputAtPress); XCTAssertEqual(press.secureInputAtAdmission, false)
        _ = manager.handleEvent(type: .flagsChanged, event: event(61))
        XCTAssertEqual(press.keyDownCount, 2)
        _ = manager.handleEvent(type: .flagsChanged, event: event(61, 0x40))
        XCTAssertEqual(manager.currentPress?.keyDownCount, 0)
        XCTAssertEqual(manager.currentPress?.secureInputAtPress, false)
    }

    func testSettingsWindowCloseClearsMoveNoteWithoutChangingBindings() throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.shortcut-close-note")
        defer { suite.destroy() }
        let config = AppConfig.forUpgradeTesting(defaults: suite.defaults)
        let model = ShortcutSettingsModel(config: config)
        let settingsWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        let unrelatedWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        unrelatedWindow.isReleasedWhenClosed = false
        model.observeSettingsWindow(settingsWindow)
        model.select(dictation: .rightCommand)
        let moved = model.bindings
        unrelatedWindow.close()
        XCTAssertNotNil(model.captionAdjustment)
        settingsWindow.close()
        XCTAssertNil(model.captionAdjustment)
        XCTAssertEqual(model.bindings, moved)
        XCTAssertEqual(config.shortcutBindings, moved)
    }

    func testTaggedSyntheticPasteDoesNotCancelButUntaggedPasteDoes() {
        for tagged in [true, false] {
            let manager = HotkeyManager(secureInput: { false }); var releases = 0, cancellations = 0
            manager.onRelease = { releases += 1 }; manager.onCancelledRelease = { _ in cancellations += 1 }
            _ = manager.handleEvent(type: .flagsChanged, event: event(61, 0x40))
            let paste = event(9, CGEventFlags.maskCommand.rawValue)
            if tagged { paste.setIntegerValueField(.eventSourceUserData, value: ShortcutBindings.syntheticEventTag) }
            XCTAssertTrue(manager.handleEvent(type: .keyDown, event: paste) != nil)
            _ = manager.handleEvent(type: .flagsChanged, event: event(61))
            XCTAssertEqual(releases, tagged ? 1 : 0); XCTAssertEqual(cancellations, tagged ? 0 : 1)
        }
        XCTAssertEqual(ShortcutBindings.default.classify(type: .keyDown, keyCode: 44,
            flags: .init(rawValue: CGEventFlags.maskCommand.rawValue | 0x10),
            userData: ShortcutBindings.syntheticEventTag), .passThrough)
    }

    func testRebindRetiresOnceBeforeSwapAndOldKeyPassesThroughWithoutATap() {
        let manager = HotkeyManager(secureInput: { false }); var presses = 0, cancellations = 0, releases = 0
        manager.onPress = { presses += 1 }; manager.onRelease = { releases += 1 }
        manager.onCancelledRelease = { _ in
            cancellations += 1
            XCTAssertEqual(manager.bindings, .default, "retirement must precede swap")
        }
        _ = manager.handleEvent(type: .flagsChanged, event: event(61, 0x40))
        manager.apply(.init(dictation: .rightCommand, liveCaption: .off))
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(61)) != nil)
        XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(61, 0x40)) != nil)
        _ = manager.handleEvent(type: .flagsChanged, event: event(54, 0x10))
        _ = manager.handleEvent(type: .flagsChanged, event: event(54))
        XCTAssertEqual(presses, 2); XCTAssertEqual(releases, 1); XCTAssertEqual(cancellations, 1)
    }

    func testRebindBetweenTapsClearsDeferredSingleAndSecondTapIntent() async throws {
        let manager = HotkeyManager(secureInput: { false })
        let arbiter = TapArbiter()
        manager.onBindingsWillChange = { arbiter.reset() }
        var translations = 0
        arbiter.deferSingleTap { translations += 1 }
        manager.apply(.init(dictation: .rightControl, liveCaption: .off))
        XCTAssertFalse(arbiter.hasPendingAction)
        XCTAssertFalse(arbiter.cancelPendingForSecondPress())
        XCTAssertFalse(arbiter.consumeSecondTapCandidate())
        try await Task.sleep(for: .seconds(TapArbiter.doubleTapWindow + 0.05))
        XCTAssertEqual(translations, 0)
        arbiter.deferSingleTap { translations += 1 }
        XCTAssertTrue(arbiter.cancelPendingForSecondPress())
        manager.apply(.default)
        XCTAssertFalse(arbiter.consumeSecondTapCandidate())
    }

    func testHealthyTapRetainsEveryBindingUntilItsReleaseEvenWhenAllReadersSayUp() {
        for key in DictationKey.allCases {
            var tapEnabled = false
            let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off),
                                        keyStateReader: { _, _ in false }, modifierFlags: { _ in 0 },
                                        keyboardTapEnabled: { _ in tapEnabled }, secureInput: { false })
            var releases = 0, cancellations = 0
            manager.onRelease = { releases += 1 }
            manager.onCancelledRelease = { _ in cancellations += 1 }
            _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode, key.deviceBit))
            manager.checkForLostRelease()
            tapEnabled = true
            let paste = event(9, CGEventFlags.maskCommand.rawValue)
            paste.setIntegerValueField(.eventSourceUserData, value: ShortcutBindings.syntheticEventTag)
            _ = manager.handleEvent(type: .keyDown, event: paste)
            for _ in 0..<60 { manager.checkForLostRelease() }
            tapEnabled = false
            manager.checkForLostRelease()
            XCTAssertNotNil(manager.currentPress, "Restoring tap health must reset the pending up sample")
            _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode))
            XCTAssertEqual(releases, 1)
            XCTAssertEqual(cancellations, 0)
        }
    }

    func testUnavailableTapRequiresConsecutiveUpReadingsAndResetsOnDown() {
        var physicalDown = true
        let manager = HotkeyManager(keyIsDown: { _ in physicalDown }, keyboardTapEnabled: { _ in false }, secureInput: { false })
        var cancellations = 0, releases = 0
        manager.onCancelledRelease = { _ in cancellations += 1 }; manager.onRelease = { releases += 1 }
        _ = manager.handleEvent(type: .flagsChanged, event: event(61, 0x40))
        manager.checkForLostRelease()
        physicalDown = false
        manager.checkForLostRelease(); XCTAssertEqual(cancellations, 0)
        physicalDown = true
        manager.checkForLostRelease()
        physicalDown = false
        manager.checkForLostRelease(); XCTAssertEqual(cancellations, 0, "Down resets the consecutive count")
        manager.checkForLostRelease(); manager.checkForLostRelease()
        _ = manager.handleEvent(type: .flagsChanged, event: event(61))
        XCTAssertEqual(cancellations, 1); XCTAssertEqual(releases, 0)
    }

    /// Karabiner and posted events leave `keyState` false for a held modifier;
    /// only the side bit in the flag state shows the hold (MBP, build 66).
    func testWatchdogKeepsHoldWhileSideBitIsSetEvenWhenKeyStateReadsUp() {
        for key in DictationKey.allCases {
            var flags: UInt64 = 0x100 | key.deviceBit
            let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off),
                keyIsDown: { _ in false }, modifierFlags: { _ in flags }, secureInput: { false })
            var cancellations = 0
            manager.onCancelledRelease = { _ in cancellations += 1 }
            _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode, key.deviceBit))
            for _ in 0..<10 { manager.checkForLostRelease() }
            XCTAssertEqual(cancellations, 0, "\(key) hold must survive while its side bit is set")
            let otherSides: UInt64 = (0x20 | 0x08 | 0x01 | 0x40 | 0x10 | 0x2000) & ~key.deviceBit
            flags = 0x100 | otherSides
            manager.checkForLostRelease(); manager.checkForLostRelease()
            XCTAssertEqual(cancellations, 1, "\(key): another side's bit must not keep the hold alive")
        }
    }

    func testQueuedReleaseAfterOneUpReadingStillCompletesCleanHold() {
        let manager = HotkeyManager(keyIsDown: { _ in false }, secureInput: { false })
        var cancellations = 0, releases = 0
        manager.onCancelledRelease = { _ in cancellations += 1 }; manager.onRelease = { releases += 1 }
        for _ in 0..<2 {
            _ = manager.handleEvent(type: .flagsChanged, event: event(61, 0x40))
            manager.checkForLostRelease()
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(61)) == nil)
            manager.checkForLostRelease()
        }
        XCTAssertEqual(cancellations, 0); XCTAssertEqual(releases, 2)
    }

    func testNativeE2EDisablesWatchdogWithoutReadingPhysicalState() {
        XCTAssertFalse(HotkeyManager.watchdogAllowed(arguments: ["--native-e2e"]))
        XCTAssertTrue(HotkeyManager.watchdogAllowed(arguments: []))
        var readings = 0
        let manager = HotkeyManager(keyIsDown: { _ in readings += 1; return false },
            watchdogEnabled: HotkeyManager.watchdogAllowed(arguments: ["--native-e2e"]), secureInput: { false })
        _ = manager.handleEvent(type: .flagsChanged, event: event(61, 0x40))
        for _ in 0..<10 { manager.checkForLostRelease() }
        XCTAssertEqual(readings, 0)
        XCTAssertTrue(manager.rightOptionIsDownForTesting)
        XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(61)) == nil)
    }

    func testChordReleasePassesThroughWhileCleanHoldAndTapStaySuppressed() {
        for key in DictationKey.allCases {
            let manager = HotkeyManager(bindings: .init(dictation: key, liveCaption: .off), secureInput: { false })
            var releases = 0, cancellations = 0
            manager.onRelease = { releases += 1 }; manager.onCancelledRelease = { _ in cancellations += 1 }
            _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode, key.deviceBit))
            _ = manager.handleEvent(type: .keyDown, event: event(9))
            let release = event(key.keyCode)
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: release)?.takeUnretainedValue() === release)
            XCTAssertEqual(cancellations, 1)
            _ = manager.handleEvent(type: .flagsChanged, event: event(key.keyCode, key.deviceBit))
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(key.keyCode)) == nil)
            XCTAssertEqual(releases, 1)
        }
    }

    func testQuickCommandTapDoesNotDispatchTranslationWhileLiveIsFinalizing() async throws {
        let driver = ChordCaptureDriver()
        let capture = AudioCaptureService(makeDriver: { driver })
        var clock: TimeInterval = 0
        var recognitionGate: CheckedContinuation<Void, Never>?
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { false },
            acquireOwnership: { _ in true }, releaseOwnership: { _ in },
            recognize: { _ in LiveRecognition(text: "kept transcript", generatedTokens: 3, endedByEOS: true) })
        session.prepareRecognition = { await withCheckedContinuation { recognitionGate = $0 } }
        session.prepareFinal = { $0 }
        XCTAssertTrue(try session.start(automaticTicks: false))
        driver.emit(8000); clock = 1
        session.release()
        for _ in 0..<1000 {
            if recognitionGate != nil { break }
            await Task.yield()
        }
        let gate = try XCTUnwrap(recognitionGate)
        defer { gate.resume(); session.cancel() }
        XCTAssertEqual(session.phase, .finalizing)
        let delegate = AppDelegate()
        var tapDispatches = 0
        delegate.releaseQuickTapForTesting(session: session, key: .rightCommand, elapsed: 0.1,
                                          onTap: { tapDispatches += 1 })
        XCTAssertEqual(tapDispatches, 0, "No tap translation or clipboard work may run during a Live final paste")
        XCTAssertEqual(session.phase, .finalizing)
        XCTAssertFalse(session.cancelled)
        let secureNotice = delegate.showSecureInputNoticeForTesting(session: session, key: .rightCommand)
        XCTAssertFalse(secureNotice.notice)
        XCTAssertTrue(secureNotice.live, "A secure pause notice must preserve the finalizing Live overlay")
        let idleNotice = delegate.showSecureInputNoticeForTesting(session: nil, key: .rightCommand)
        XCTAssertTrue(idleNotice.notice)
        XCTAssertFalse(idleNotice.live)
        // Positive control: a quick tap with no Live owner still takes the tap path.
        delegate.releaseQuickTapForTesting(session: nil, key: .rightCommand, elapsed: 0.1,
                                          onTap: { tapDispatches += 1 })
        XCTAssertEqual(tapDispatches, 1)
    }

    func testFinalizingLiveSessionSurvivesNewChordAndCancelledReleaseAndDeliversResult() async throws {
        let driver = ChordCaptureDriver()
        let capture = AudioCaptureService(makeDriver: { driver })
        var clock: TimeInterval = 0
        var ownsLease = false
        var recognitionGate: CheckedContinuation<Void, Never>?
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { false },
            acquireOwnership: { _ in ownsLease = true; return true }, releaseOwnership: { _ in ownsLease = false },
            recognize: { _ in LiveRecognition(text: "kept transcript", generatedTokens: 3, endedByEOS: true) })
        session.prepareRecognition = { await withCheckedContinuation { recognitionGate = $0 } }
        session.prepareFinal = { $0 }
        let result = expectation(description: "Released session delivers its final transcript")
        session.onResult = { text, _ in XCTAssertEqual(text, "kept transcript"); result.fulfill() }
        XCTAssertTrue(try session.start(automaticTicks: false))
        driver.emit(8000); clock = 1
        session.release()
        XCTAssertEqual(session.phase, .finalizing)
        for _ in 0..<1000 {
            if recognitionGate != nil { break }
            await Task.yield()
        }
        let gate = try XCTUnwrap(recognitionGate)
        let delegate = AppDelegate()
        let manager = HotkeyManager(bindings: .init(dictation: .rightCommand, liveCaption: .off), secureInput: { false })
        delegate.connectLiveSessionForTesting(session, hotkey: manager)
        _ = manager.handleEvent(type: .flagsChanged, event: event(54, 0x10))
        _ = manager.handleEvent(type: .keyDown, event: event(9))
        XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(54)) != nil)
        XCTAssertEqual(session.phase, .finalizing)
        XCTAssertFalse(session.cancelled)
        // Also exercise the cancelled-release handler without a preceding
        // chord (e.g. an interrupted tap), covering its independent phase guard.
        _ = manager.handleEvent(type: .flagsChanged, event: event(54, 0x10))
        manager.apply(manager.bindings)
        XCTAssertEqual(session.phase, .finalizing)
        XCTAssertFalse(session.cancelled)
        gate.resume(); recognitionGate = nil
        await fulfillment(of: [result], timeout: 3)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertFalse(ownsLease)
    }

    func testConflictMatrixAndPersistenceRoundTripRejectInvalidPair() throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.shortcuts-test")
        defer { suite.destroy() }
        let config = AppConfig.forUpgradeTesting(defaults: suite.defaults)
        for key in DictationKey.allCases {
            for caption in CaptionShortcut.allCases {
                let pair = ShortcutBindings(dictation: key, liveCaption: caption)
                let expected = caption == .rightCmdSlash && key == .rightCommand
                XCTAssertEqual(pair.hasConflict, expected, "\(key) / \(caption)")
                let previous = config.shortcutBindings
                config.shortcutBindings = pair
                XCTAssertEqual(config.shortcutBindings, expected ? previous : pair)
                XCTAssertEqual(AppConfig.forUpgradeTesting(defaults: suite.defaults).shortcutBindings, expected ? previous : pair)
            }
        }
    }

    func testSettingsNotificationRefreshesCachedPaneModelSynchronously() throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.shortcuts-model-test")
        defer { suite.destroy() }
        let config = AppConfig.forUpgradeTesting(defaults: suite.defaults)
        let model = ShortcutSettingsModel(config: config)
        model.select(caption: .off)
        XCTAssertEqual(model.bindings.liveCaption, .off)
        model.select(dictation: .rightCommand)
        XCTAssertEqual(model.bindings.dictation, .rightCommand)
        config.shortcutBindings = .default
        XCTAssertEqual(model.bindings, .default)
    }

    func testPickingRightCommandMovesDefaultCaptionWithOneCompletePreferenceWrite() throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.shortcut-adjustment-test")
        defer { suite.destroy() }
        let store = try XCTUnwrap(ShortcutObservedDefaults(suiteName: suite.name))
        // An existing install can have the two original stable-ID preferences.
        store.setPersistentDomain([
            "hushtype.shortcut.dictationKey": "rightOption",
            "hushtype.shortcut.liveCaption": "rightCmdSlash",
            "fixture.keep": "unchanged",
        ], forName: suite.name)
        let config = AppConfig.forUpgradeTesting(defaults: store)
        let model = ShortcutSettingsModel(config: config)
        let expected = ShortcutBindings(dictation: .rightCommand, liveCaption: .controlOptionSlash)
        var writes = 0
        store.afterWrite = { key in
            writes += 1
            XCTAssertEqual(key, "hushtype.shortcut.bindings")
            // Inspect raw storage after every write, rather than the getter's
            // invalid-pair fallback, so a transient conflict cannot be hidden.
            XCTAssertEqual(store.dictionary(forKey: key) as? [String: String], [
                "dictationKey": "rightCommand", "liveCaption": "controlOptionSlash",
            ])
        }
        model.select(dictation: .rightCommand)
        store.afterWrite = nil
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.bindings, expected)
        XCTAssertEqual(model.captionAdjustment, expected)
        XCTAssertEqual(config.shortcutBindings, expected)
        XCTAssertEqual(AppConfig.forUpgradeTesting(defaults: suite.defaults).shortcutBindings, expected)
        XCTAssertEqual(store.string(forKey: "fixture.keep"), "unchanged")
        // Legacy preferences are only read; the complete pair takes precedence.
        XCTAssertEqual(store.string(forKey: "hushtype.shortcut.dictationKey"), "rightOption")
    }

    func testEveryDictationKeyIsAcceptedAndOnlyConflictingCaptionsMove() throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.shortcut-adjustment-matrix")
        defer { suite.destroy() }
        let config = AppConfig.forUpgradeTesting(defaults: suite.defaults)
        let model = ShortcutSettingsModel(config: config)
        for previousKey in DictationKey.allCases {
            for caption in CaptionShortcut.allCases {
                let initial = ShortcutBindings(dictation: previousKey, liveCaption: caption)
                guard !initial.hasConflict else { continue }
                for nextKey in DictationKey.allCases {
                    config.shortcutBindings = initial
                    let conflicts = ShortcutBindings(dictation: nextKey, liveCaption: caption).hasConflict
                    model.select(dictation: nextKey)
                    XCTAssertEqual(model.bindings.dictation, nextKey)
                    XCTAssertFalse(model.bindings.hasConflict)
                    let expectedCaption: CaptionShortcut = conflicts
                        ? (nextKey == .rightCommand ? .controlOptionSlash : .rightCmdSlash) : caption
                    XCTAssertEqual(model.bindings.liveCaption, expectedCaption)
                    XCTAssertEqual(model.captionAdjustment != nil, conflicts)
                }
            }
        }
    }

    func testExplicitCaptionChoiceClearsMoveNoteAndStillRejectsConflicts() throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.shortcut-adjustment-note")
        defer { suite.destroy() }
        let config = AppConfig.forUpgradeTesting(defaults: suite.defaults)
        let model = ShortcutSettingsModel(config: config)
        model.select(dictation: .rightCommand)
        let adjusted = model.bindings
        XCTAssertEqual(model.captionAdjustment, adjusted)
        model.select(caption: .rightCmdSlash)
        XCTAssertEqual(model.bindings, adjusted)
        model.select(caption: .off)
        XCTAssertEqual(model.bindings.liveCaption, .off)
        XCTAssertNil(model.captionAdjustment)
        model.select(dictation: .rightOption)
        XCTAssertEqual(model.bindings.liveCaption, .off, "An explicitly disabled caption shortcut stays off")
        XCTAssertNil(model.captionAdjustment)
    }

    func testInvalidStoredIDsAndConflictingPairFallBackWithoutWriting() throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.shortcuts-invalid-test")
        defer { suite.destroy() }
        for values: [String: Any] in [
            [:], ["hushtype.shortcut.dictationKey": "unknown"],
            ["hushtype.shortcut.liveCaption": 123],
            ["hushtype.shortcut.bindings": "invalid"],
            ["hushtype.shortcut.bindings": ["dictationKey": "rightCommand"]],
            ["hushtype.shortcut.bindings": ["dictationKey": "rightCommand", "liveCaption": "rightCmdSlash"]],
            ["hushtype.shortcut.dictationKey": "rightCommand", "hushtype.shortcut.liveCaption": "rightCmdSlash"],
        ] {
            suite.defaults.setPersistentDomain(values, forName: suite.name)
            XCTAssertEqual(AppConfig.forUpgradeTesting(defaults: suite.defaults).shortcutBindings, .default)
            XCTAssertTrue(NSDictionary(dictionary: suite.defaults.persistentDomain(forName: suite.name) ?? [:]).isEqual(to: values))
        }
    }
}
