import XCTest
@testable import HushType

final class TranscriptionEngineLoadEpochTests: XCTestCase {
    func testLateSharedLoadWaiterCannotCommitAfterSwitch() {
        let waiterGeneration: UInt = 4
        XCTAssertTrue(Qwen3TranscriptionEngine.canCommitSharedLoad(
            waiterGeneration: waiterGeneration, currentGeneration: 4, hasModel: false))
        XCTAssertFalse(Qwen3TranscriptionEngine.canCommitSharedLoad(
            waiterGeneration: waiterGeneration, currentGeneration: 5, hasModel: true))
        XCTAssertFalse(Qwen3TranscriptionEngine.canCommitSharedLoad(
            waiterGeneration: waiterGeneration, currentGeneration: 4, hasModel: true))
    }
}
