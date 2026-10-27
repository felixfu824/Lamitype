import XCTest
@testable import HushType

@MainActor final class DefaultLiveHoldGateTests: XCTestCase {
    private final class Clock { var time: Double = 0; var work: [DispatchWorkItem] = []; var held: [Double] = [] }
    private func make(_ clock: Clock) -> DefaultLiveHoldGate {
        DefaultLiveHoldGate(now: { clock.time }, schedule: { _, work in clock.work.append(work) })
    }
    func testShortTapDoesNotPromptAndRetiresQueuedWork() {
        let c = Clock(), gate = make(c); gate.press { c.held.append($0) }
        c.time = 0.299; XCTAssertEqual(gate.release(), .tap)
        c.time = 1; c.work[0].perform(); XCTAssertTrue(c.held.isEmpty)
    }
    func testHoldPromptsOnceAndReleaseIsConsumedElsewhere() {
        let c = Clock(), gate = make(c); gate.press { c.held.append($0) }
        c.time = 0.3; c.work[0].perform()
        XCTAssertEqual(c.held, [0]); XCTAssertEqual(gate.release(), .none)
    }
    func testLateTimerDoesNotTurnHeldReleaseIntoTap() {
        let c = Clock(), gate = make(c); gate.press { c.held.append($0) }
        c.time = 0.35; XCTAssertEqual(gate.release(), .consumedHold)
        c.work[0].perform(); XCTAssertEqual(c.held, [0])
    }
    func testChordAtBoundaryCancelsBeforeQueuedHoldWork() {
        let c = Clock(), gate = make(c); gate.press { c.held.append($0) }
        c.time = 0.3; XCTAssertTrue(gate.cancel()); c.work[0].perform()
        XCTAssertEqual(gate.release(), .none); XCTAssertTrue(c.held.isEmpty)
    }
    func testSleepThenNewPressCannotBePromptedByOldTimer() {
        let c = Clock(), gate = make(c); gate.press { c.held.append($0) }
        c.time = 0.1; gate.cancel(); gate.press { c.held.append($0) }
        c.time = 1; c.work[0].perform(); XCTAssertTrue(c.held.isEmpty)
        c.work[1].perform(); XCTAssertEqual(c.held, [0.1])
    }
    func testEarlyScheduledWorkRechecksMonotonicThreshold() {
        let c = Clock(), gate = make(c); gate.press { c.held.append($0) }
        c.time = 0.2; c.work[0].perform(); XCTAssertTrue(c.held.isEmpty)
        XCTAssertEqual(c.work.count, 2)
        c.time = 0.3; c.work[1].perform(); XCTAssertEqual(c.held, [0])
    }
}
