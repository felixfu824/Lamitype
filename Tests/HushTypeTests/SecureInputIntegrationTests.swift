import Carbon
import Foundation
import XCTest
@testable import HushType

@MainActor
final class SecureInputIntegrationTests: XCTestCase {
    func testCarbonSecureInputSuppressesEvalCaptureThenCaptureResumes() async throws {
        guard ProcessInfo.processInfo.environment["LAMITYPE_RUN_SECURE_INPUT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LAMITYPE_RUN_SECURE_INPUT_INTEGRATION=1 to run the OS-backed Secure Input check")
        }
        guard !SecureInputProbe.isActive() else {
            throw XCTSkip("Secure Input was already active; refusing to alter externally owned state")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("secure-input-integration-\(UUID().uuidString)", isDirectory: true)
        let store = EvalStore(directory: root)
        let previousEvalEnabled = AppConfig.shared.evalModeEnabled
        var ownsSecureInput = false
        defer {
            if ownsSecureInput {
                _ = DisableSecureEventInput()
            }
            AppConfig.shared.evalModeEnabled = previousEvalEnabled
            EvalCapture.resetCountersForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        AppConfig.shared.evalModeEnabled = true
        EvalCapture.resetCountersForTesting()

        let enableStatus = EnableSecureEventInput()
        XCTAssertEqual(enableStatus, noErr)
        guard enableStatus == noErr else { return }
        ownsSecureInput = true
        XCTAssertTrue(SecureInputProbe.isActive())

        recordSyntheticEntry(store: store, suffix: "suppressed")
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(EvalCapture.suppressedCount, 1)

        let disableStatus = DisableSecureEventInput()
        XCTAssertEqual(disableStatus, noErr)
        guard disableStatus == noErr else { return }
        ownsSecureInput = false
        XCTAssertFalse(SecureInputProbe.isActive())

        recordSyntheticEntry(store: store, suffix: "captured")
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.entries.first?.original, "synthetic captured input")
        XCTAssertEqual(EvalCapture.suppressedCount, 1)
        await store.waitForPendingIO()
    }

    private func recordSyntheticEntry(store: EvalStore, suffix: String) {
        EvalCapture.record(
            source: .dictation,
            appBundleID: "com.example.secure-input-integration",
            original: "synthetic \(suffix) input",
            output: "synthetic \(suffix) output",
            outcome: .polished,
            reason: nil,
            elapsed: 0.001,
            abandoned: false,
            excludedBundleIDs: [],
            store: store
        )
    }
}
