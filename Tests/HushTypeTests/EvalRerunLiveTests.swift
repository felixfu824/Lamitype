import Foundation
import XCTest
@testable import HushType

@MainActor
final class EvalRerunLiveTests: XCTestCase {
    func testRerunUsesInstructionsWithoutTouchingStandby() async throws {
        guard ProcessInfo.processInfo.environment["LAMITYPE_RUN_FM_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LAMITYPE_RUN_FM_INTEGRATION=1 to run Foundation Models integration")
        }
        let root = try configureIsolatedAppSupport()
        defer {
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        TextPolisher.refreshAvailabilityCache()
        guard TextPolisher.isAvailableCached else {
            throw XCTSkip(TextPolisher.unavailableReasonCached)
        }
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }

        FoundationModelsPolisher.warmup()
        let before = FoundationModelsPolisher.standbyFingerprintForTesting
        let result = await TextPolisher.rerun(
            "she go to school yesterday",
            instructions: "Never add a final period.",
            budget: .polish
        )
        let after = FoundationModelsPolisher.standbyFingerprintForTesting

        guard case .success(let output, _) = result else {
            return XCTFail("Expected rerun success")
        }
        XCTAssertTrue(output.lowercased().contains("went"))
        XCTAssertEqual(before, after)
    }

    private func configureIsolatedAppSupport() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-rerun-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let roots = AppSupportMigrator.productionRoots(in: sandbox)
        let selected = try AppSupportMigrator.migrate(oldRoot: roots.old, newRoot: roots.new).get()
        AppSupportPaths.resetForTesting()
        AppSupportPaths.configure(root: selected)
        return sandbox
    }
}
