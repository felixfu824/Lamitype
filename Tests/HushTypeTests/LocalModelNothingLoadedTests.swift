import XCTest
@testable import HushType

/// A failed launch or reload load with no fallback leaves nothing loaded:
/// Settings shows the failure and Try Again reloads.
@MainActor
final class LocalModelNothingLoadedTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var config: AppConfig!

    override func setUp() async throws {
        suiteName = "LocalModelNothingLoadedTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        config = AppConfig.forUpgradeTesting(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Failed load with nothing loaded (fresh install, no Fast fallback)

    func testNothingLoadedFailureOffersRetryOfTheSavedModel() {
        config.localModel = .optimized
        let switcher = LocalModelSwitcher(config: config)
        switcher.engine = Qwen3TranscriptionEngine()
        var retries = 0
        switcher.retryLoad = { retries += 1 }
        switcher.noteLoadFailedWithNothingLoaded(.optimized)
        XCTAssertEqual(switcher.phase, .notLoaded(.optimized))
        XCTAssertNotNil(switcher.statusText)
        // Try Again in Settings selects the shown model again.
        XCTAssertTrue(switcher.select(.optimized))
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(switcher.phase, .idle)
        XCTAssertEqual(config.localModel, .optimized)
        switcher.noteModelLoaded()
        XCTAssertEqual(switcher.phase, .idle)
    }

    func testChoosingTheOtherModelAfterANothingLoadedFailureLoadsIt() {
        config.localModel = .optimized
        let switcher = LocalModelSwitcher(config: config)
        switcher.engine = Qwen3TranscriptionEngine()
        var retries = 0
        switcher.retryLoad = { retries += 1 }
        switcher.noteLoadFailedWithNothingLoaded(.optimized)
        XCTAssertTrue(switcher.select(.fast))
        XCTAssertEqual(config.localModel, .fast)
        XCTAssertEqual(switcher.active, .fast)
        XCTAssertEqual(retries, 1, "the new choice loads now, not at the next launch")
    }

    func testNothingLoadedRetryWaitsWhileBusy() {
        config.localModel = .optimized
        let switcher = LocalModelSwitcher(config: config)
        switcher.engine = Qwen3TranscriptionEngine()
        var retries = 0
        switcher.retryLoad = { retries += 1 }
        switcher.isBusy = { true }
        switcher.noteLoadFailedWithNothingLoaded(.optimized)
        XCTAssertFalse(switcher.select(.optimized))
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(switcher.phase, .notLoaded(.optimized))
    }

    func testLoadSuccessClearsANothingLoadedFailure() {
        let switcher = LocalModelSwitcher(config: config)
        switcher.noteLoadFailedWithNothingLoaded(.optimized)
        switcher.noteModelLoaded()
        XCTAssertEqual(switcher.phase, .idle)
    }
}
