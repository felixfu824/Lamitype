import AppKit
import XCTest
@testable import HushType

final class HotkeyInterruptionTests: XCTestCase {
    private func modifier(_ down: Bool) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: down)!
        event.type = .flagsChanged; event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40) : []
        return event
    }
    func testTimeoutCancelsLostHoldAndAcceptsFreshPress() {
        let manager = HotkeyManager()
        var presses = 0, releases = 0, cancellations = 0
        manager.onPress = { presses += 1 }; manager.onRelease = { releases += 1 }; manager.onCancelledRelease = { cancellations += 1 }
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
        let manager = HotkeyManager(); var cancellations = 0
        manager.onCancelledRelease = { cancellations += 1 }
        _ = manager.handleEvent(type: .tapDisabledByUserInput, event: modifier(false))
        _ = manager.handleEvent(type: .tapDisabledByTimeout, event: modifier(false))
        XCTAssertEqual(cancellations, 0); XCTAssertEqual(manager.disabledTapCount, 2)
    }
    func testInterruptionClearsChordStateBeforeNextHold() {
        let manager = HotkeyManager(); var releases = 0, cancellations = 0
        manager.onRelease = { releases += 1 }; manager.onCancelledRelease = { cancellations += 1 }
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(true))
        let arrow = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true)!
        _ = manager.handleEvent(type: .keyDown, event: arrow)
        _ = manager.handleEvent(type: .tapDisabledByUserInput, event: modifier(false))
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(true))
        _ = manager.handleEvent(type: .flagsChanged, event: modifier(false))
        XCTAssertEqual(cancellations, 1); XCTAssertEqual(releases, 1)
    }
    func testRightOptionReleaseWhileLeftStaysHeldClosesPressOnce() {
        let manager = HotkeyManager(); var presses = 0, releases = 0
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
        let manager = HotkeyManager(); var releases = 0
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

}
