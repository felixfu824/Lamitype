import XCTest
@testable import HushType

final class AutoPolishLiveTests: XCTestCase {
    func testEnglishAndMixedLanguageProofreading() async throws {
        guard ProcessInfo.processInfo.environment["LAMITYPE_RUN_FM_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LAMITYPE_RUN_FM_INTEGRATION=1 to run the Foundation Models integration test")
        }
        let appSupportSandbox = try configureIsolatedAppSupport()
        defer {
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: appSupportSandbox)
        }

        await MainActor.run { TextPolisher.refreshAvailabilityCache() }
        guard TextPolisher.isAvailableCached else {
            throw XCTSkip("Apple Foundation Models is unavailable on this Mac")
        }

        let english = "she go to school yesterday and buy three apple"
        switch await TextPolisher.polishDictation(english) {
        case .success(let polished, let changed):
            print("[AutoPolishLive] English output: \(polished)")
            XCTAssertTrue(changed)
            XCTAssertNotEqual(polished, english)
        case .failure(let error):
            XCTFail("English Auto Polish failed: \(error.localizedDescription)")
        }

        let mixed = "我今天要跟 John 開會，然後 review 一下 proposal"
        switch await TextPolisher.polishDictation(mixed) {
        case .success(let polished, _):
            print("[AutoPolishLive] Mixed output: \(polished)")
        case .failure(let error):
            XCTFail("Mixed-language Auto Polish failed: \(error.localizedDescription)")
        }
    }

    private func configureIsolatedAppSupport() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lamitype-auto-polish-live-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sandbox,
            withIntermediateDirectories: true
        )

        let roots = AppSupportMigrator.productionRoots(in: sandbox)
        let selectedRoot: URL
        switch AppSupportMigrator.migrate(oldRoot: roots.old, newRoot: roots.new) {
        case .success(let root):
            selectedRoot = root
        case .failure(let error):
            try? FileManager.default.removeItem(at: sandbox)
            throw error
        }

        AppSupportPaths.resetForTesting()
        AppSupportPaths.configure(root: selectedRoot)
        return sandbox
    }
}
