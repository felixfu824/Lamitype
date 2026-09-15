import XCTest
@testable import HushType

/// Notice ownership and per-press presentation policy. No NSPanel, no
/// AppDelegate, no sleeping: expiry is invoked directly with saved tickets,
/// exactly as the production timer body does.
@MainActor
final class CaptureNoticeTests: XCTestCase {

    // MARK: - OverlayStateModel notice policy

    func testNoticeIsShownAndThenHiddenByItsOwnExpiry() {
        let model = OverlayStateModel()
        XCTAssertEqual(model.state, .hidden)
        XCTAssertFalse(model.isShowingNotice)

        let ticket = model.beginNotice(message: "Nothing was inserted. Device changed.")
        XCTAssertEqual(model.state, .notice(message: "Nothing was inserted. Device changed."))
        XCTAssertTrue(model.isShowingNotice)

        XCTAssertTrue(model.expireNotice(ticket))
        XCTAssertEqual(model.state, .hidden)
        XCTAssertFalse(model.isShowingNotice)

        // The ticket is retired, so a repeat expiry reports that it hid nothing.
        XCTAssertFalse(model.expireNotice(ticket))
    }

    func testExpiryIsIgnoredOnceTheNoticeBecameRecording() {
        let model = OverlayStateModel()
        let ticket = model.beginNotice(message: "Nothing was inserted. No audio.")

        model.state = .recording(level: 0, provider: nil)

        XCTAssertFalse(model.expireNotice(ticket))
        XCTAssertEqual(model.state, .recording(level: 0, provider: nil))
    }

    func testExpiryIsIgnoredOnceTheNoticeBecameTranscribingOrPolishing() {
        let transcribing = OverlayStateModel()
        let transcribingTicket = transcribing.beginNotice(message: "Nothing was inserted.")
        transcribing.state = .transcribing(provider: nil)
        XCTAssertFalse(transcribing.expireNotice(transcribingTicket))
        XCTAssertEqual(transcribing.state, .transcribing(provider: nil))

        let polishing = OverlayStateModel()
        let polishingTicket = polishing.beginNotice(message: "Nothing was inserted.")
        polishing.state = .polishing
        XCTAssertFalse(polishing.expireNotice(polishingTicket))
        XCTAssertEqual(polishing.state, .polishing)
    }

    func testASecondNoticeWithIdenticalWordingIgnoresTheFirstTicket() {
        let model = OverlayStateModel()
        let message = "Nothing was inserted. The audio device changed."
        let first = model.beginNotice(message: message)
        let second = model.beginNotice(message: message)

        // Identical text, different owners: only the live ticket may dismiss.
        XCTAssertFalse(model.expireNotice(first))
        XCTAssertTrue(model.isShowingNotice)
        XCTAssertEqual(model.state, .notice(message: message))

        XCTAssertTrue(model.expireNotice(second))
        XCTAssertEqual(model.state, .hidden)
    }

    func testInvalidateNoticeHidesItAndCancelsAPendingExpiry() {
        let model = OverlayStateModel()
        let ticket = model.beginNotice(message: "Nothing was inserted.")

        model.invalidateNotice()
        XCTAssertEqual(model.state, .hidden)
        XCTAssertFalse(model.isShowingNotice)

        // The cancelled press's timer must report that it hid nothing, so the
        // caller does not order the panel out from under a later state.
        XCTAssertFalse(model.expireNotice(ticket))
    }

    func testInvalidateNoticeLeavesANonNoticeStateUntouched() {
        let model = OverlayStateModel()
        model.state = .recording(level: 0.2, provider: "OpenAI")

        model.invalidateNotice()

        XCTAssertEqual(model.state, .recording(level: 0.2, provider: "OpenAI"))
    }

    func testHidingDirectlyAlsoRetiresTheTicket() {
        let model = OverlayStateModel()
        let ticket = model.beginNotice(message: "Nothing was inserted.")

        model.state = .hidden

        XCTAssertFalse(model.expireNotice(ticket))
    }

    // MARK: - Per-press presentation claim

    func testAPressClaimsItsErrorPresentationExactlyOnce() {
        let press = DictationPressRecord(keyDownUptime: 100)

        XCTAssertTrue(press.claimErrorPresentation())
        XCTAssertTrue(press.errorPresented)
        XCTAssertFalse(press.claimErrorPresentation())
        XCTAssertFalse(press.claimErrorPresentation())
    }

    func testACancelledPressNeverClaims() {
        let press = DictationPressRecord(keyDownUptime: 100)
        press.cancelled = true

        XCTAssertFalse(press.claimErrorPresentation())
        XCTAssertFalse(press.errorPresented)
    }

    func testCancellingAfterAClaimDoesNotUnsetTheClaim() {
        let press = DictationPressRecord(keyDownUptime: 100)
        XCTAssertTrue(press.claimErrorPresentation())

        press.cancelled = true

        XCTAssertFalse(press.claimErrorPresentation())
        XCTAssertTrue(press.errorPresented)
    }

    func testANewPressClaimsIndependentlyOfAnEarlierOne() {
        let first = DictationPressRecord(keyDownUptime: 100)
        XCTAssertTrue(first.claimErrorPresentation())
        XCTAssertFalse(first.claimErrorPresentation())

        let second = DictationPressRecord(keyDownUptime: 200)
        XCTAssertTrue(second.claimErrorPresentation())
    }

    func testADisplayedNoticeStaysDismissibleAfterItsPressIsReleased() {
        let model = OverlayStateModel()
        var ticket: NoticeTicket?
        weak var weakPress: DictationPressRecord?

        do {
            let press = DictationPressRecord(keyDownUptime: 100)
            weakPress = press
            XCTAssertTrue(press.claimErrorPresentation())
            ticket = model.beginNotice(message: "Nothing was inserted. No audio.")
            XCTAssertNotNil(weakPress)
        }

        // Normal release drops the record; the notice outlives it and is still
        // owned by its own ticket.
        XCTAssertNil(weakPress)
        XCTAssertTrue(model.isShowingNotice)
        XCTAssertTrue(model.expireNotice(try! XCTUnwrap(ticket)))
        XCTAssertEqual(model.state, .hidden)
    }
}
