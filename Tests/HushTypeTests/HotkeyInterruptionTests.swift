import AppKit
import XCTest
@testable import HushType

final class HotkeyInterruptionTests: XCTestCase {
    private func modifier(_ down: Bool) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: down)!
        event.type = .flagsChanged; event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40) : []
        return event
    }

    func testDurationCapRetiresOnlyItsHoldAndIgnoresStaleRelease() throws {
        let manager = HotkeyManager(secureInput: { false })
        var presses = 0, releases = 0, cancellations = 0
        manager.onPress = { presses += 1 }
        manager.onRelease = { releases += 1 }
        manager.onCancelledRelease = { _ in cancellations += 1 }

        _ = manager.handleEvent(type: .flagsChanged, event: modifier(true))
        let cappedPress = try XCTUnwrap(manager.currentPress)
        XCTAssertTrue(manager.retireDurationCappedHold(cappedPress))
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(false))
        XCTAssertNil(manager.currentPress)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 0)

        _ = manager.handleEvent(type: .flagsChanged, event: modifier(true))
        XCTAssertFalse(manager.retireDurationCappedHold(cappedPress))
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(false))
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(cancellations, 0)
    }
    func testTimeoutCancelsLostHoldAndAcceptsFreshPress() {
        let manager = HotkeyManager(secureInput: { false })
        var presses = 0, releases = 0, cancellations = 0
        manager.onPress = { presses += 1 }; manager.onRelease = { releases += 1 }; manager.onCancelledRelease = { _ in cancellations += 1 }
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(true))
        _ = manager.handleEvent(type: .tapDisabledByTimeout, event: modifier(false))
        XCTAssertEqual(cancellations, 1); XCTAssertEqual(releases, 0)
        XCTAssertFalse(manager.rightOptionIsDownForTesting)
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(false)) // stale release
        XCTAssertEqual(releases, 0)
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(true))
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(false))
        XCTAssertEqual(presses, 2); XCTAssertEqual(releases, 1); XCTAssertEqual(cancellations, 1)
    }
    func testIdleDisableNeverCancelsAnotherPress() {
        let manager = HotkeyManager(secureInput: { false }); var cancellations = 0
        manager.onCancelledRelease = { _ in cancellations += 1 }
        _ = manager.handleEvent(type: .tapDisabledByUserInput, event: modifier(false))
        _ = manager.handleEvent(type: .tapDisabledByTimeout, event: modifier(false))
        XCTAssertEqual(cancellations, 0); XCTAssertEqual(manager.disabledTapCount, 2)
    }
    func testInterruptionClearsChordStateBeforeNextHold() {
        let manager = HotkeyManager(secureInput: { false }); var releases = 0, cancellations = 0
        manager.onRelease = { releases += 1 }; manager.onCancelledRelease = { _ in cancellations += 1 }
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(true))
        let arrow = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true)!
        _ = manager.handleEvent(type: .keyDown, event: arrow)
        _ = manager.handleEvent(type: .tapDisabledByUserInput, event: modifier(false))
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(true))
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(false))
        XCTAssertEqual(cancellations, 1); XCTAssertEqual(releases, 1)
    }
    func testRightOptionReleaseWhileLeftStaysHeldClosesPressOnce() {
        let manager = HotkeyManager(secureInput: { false }); var presses = 0, releases = 0
        manager.onPress = { presses += 1 }; manager.onRelease = { releases += 1 }
        let both = modifier(true); both.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x60)
        _ = manager.handleEvent(type: .flagsChanged, event: both)
        let rightUp = modifier(false); rightUp.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        _ = manager.handleEvent(type: .flagsChanged, event: rightUp)
        XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 1); XCTAssertFalse(manager.rightOptionIsDownForTesting)
        let leftUp = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: false)!
        leftUp.type = .flagsChanged; leftUp.flags = []
        _ = manager.handleEvent(type: .flagsChanged, event: leftUp)
        XCTAssertEqual(releases, 1)
    }
    func testLeftOptionReleaseDoesNotCloseRightOptionPress() {
        let manager = HotkeyManager(secureInput: { false }); var releases = 0
        manager.onRelease = { releases += 1 }
        let both = modifier(true); both.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x60)
        _ = manager.handleEvent(type: .flagsChanged, event: both)
        let leftUp = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: false)!
        leftUp.type = .flagsChanged; leftUp.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        _ = manager.handleEvent(type: .flagsChanged, event: leftUp)
        XCTAssertEqual(releases, 0); XCTAssertTrue(manager.rightOptionIsDownForTesting)
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(false))
        XCTAssertEqual(releases, 1)
    }

    func testMouseObservationNeverUsesFilteringMaskAndRebindKeepsChordPolicy() {
        XCTAssertEqual(HotkeyManager.mouseTapOptions, .listenOnly)
        XCTAssertEqual(HotkeyManager.keyboardEventMask,
                       (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        XCTAssertEqual(HotkeyManager.mouseEventMask,
                       (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue))
        XCTAssertEqual(HotkeyManager.keyboardEventMask & HotkeyManager.mouseEventMask, 0)
        let manager = HotkeyManager(secureInput: { false })
        var chords = 0
        manager.onChordDuringHold = { chords += 1 }
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(true))
        XCTAssertTrue(manager.handleMouseEvent(type: .leftMouseDown, event: click).takeUnretainedValue() === click)
        XCTAssertEqual(chords, 0)
        manager.apply(.init(dictation: .rightCommand, liveCaption: .off))
        let command = CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true)!
        command.flags = CGEventFlags(rawValue: 0x10)
        _ = manager.handleEvent(type: .flagsChanged, event: command)
        click.flags = CGEventFlags(rawValue: DictationKey.rightCommand.deviceBit)
        XCTAssertTrue(manager.handleMouseEvent(type: .leftMouseDown, event: click).takeUnretainedValue() === click)
        XCTAssertEqual(chords, 1)
        manager.stop()
    }

    func testMouseTapDisableRetiresHoldAndClearsCaptionLatchLikeKeyboardTap() {
        for type: CGEventType in [.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let manager = HotkeyManager(secureInput: { false })
            var cancellations = 0, toggles = 0, releases = 0
            manager.onCancelledRelease = { _ in cancellations += 1 }
            manager.onRelease = { releases += 1 }
            manager.onLiveCaptionToggle = { toggles += 1 }
            _ = manager.handleEvent(type: .flagsChanged, event: modifier(true))
            let slash = CGEvent(keyboardEventSource: nil, virtualKey: 44, keyDown: true)!
            slash.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
            XCTAssertNil(manager.handleEvent(type: .keyDown, event: slash))
            XCTAssertEqual(toggles, 1)
            let notice = modifier(false)
            XCTAssertTrue(manager.handleMouseEvent(type: type, event: notice).takeUnretainedValue() === notice)
            XCTAssertEqual(cancellations, 1)
            XCTAssertFalse(manager.rightOptionIsDownForTesting)
            XCTAssertNil(manager.handleEvent(type: .keyDown, event: slash))
            XCTAssertEqual(toggles, 2, "Disable must clear the consumed caption-key latch")
            _ = manager.handleEvent(type: .flagsChanged, event: modifier(true))
            _ = manager.handleEvent(type: .flagsChanged, event: modifier(false))
            XCTAssertEqual(releases, 1)
        }
    }

}
