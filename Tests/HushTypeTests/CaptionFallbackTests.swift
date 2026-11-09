import XCTest
@testable import HushType

@MainActor
final class CaptionFallbackTests: XCTestCase {
    func testCaptionFallbackReportsFastAndKeepsSavedChoice() async throws {
        let suite = "CaptionFallbackTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = AppConfig.forUpgradeTesting(defaults: defaults)
        config.localModel = .optimized
        let switcher = LocalModelSwitcher(config: config)
        var receivedFallback: String?
        try await LiveCaptionManager.loadCaptionModel(
            fallbackModelID: config.fallbackModelSource,
            loader: { fallback in receivedFallback = fallback; return true },
            noteFallback: { switcher.noteLoadFallback(failed: .optimized, using: .fast) }
        )
        XCTAssertEqual(receivedFallback, AppConfig.LocalModel.fast.huggingFaceID)
        XCTAssertEqual(switcher.active, .fast)
        XCTAssertEqual(switcher.phase, .loadFailed(.optimized))
        XCTAssertEqual(config.localModel, .optimized)
    }
}
