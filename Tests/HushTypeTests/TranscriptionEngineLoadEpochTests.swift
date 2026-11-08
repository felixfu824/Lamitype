import XCTest
@testable import HushType

final class TranscriptionEngineLoadEpochTests: XCTestCase {
    func testLateSharedLoadWaiterCannotCommitAfterSwitch() {
        let waiterGeneration: UInt = 4
        let loaded = NSObject()
        XCTAssertTrue(Qwen3TranscriptionEngine.canCommitSharedLoad(
            waiterGeneration: waiterGeneration, currentGeneration: 4,
            installedModel: nil as NSObject?, loadedModel: loaded))
        XCTAssertFalse(Qwen3TranscriptionEngine.canCommitSharedLoad(
            waiterGeneration: waiterGeneration, currentGeneration: 5,
            installedModel: loaded, loadedModel: loaded))
        XCTAssertFalse(Qwen3TranscriptionEngine.canCommitSharedLoad(
            waiterGeneration: waiterGeneration, currentGeneration: 4,
            installedModel: NSObject(), loadedModel: loaded))
    }
}
