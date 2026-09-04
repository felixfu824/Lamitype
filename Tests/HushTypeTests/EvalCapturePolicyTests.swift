import Foundation
import XCTest
@testable import HushType

@MainActor
final class EvalCapturePolicyTests: XCTestCase {
    func testDecisionOrderAndCapture() {
        XCTAssertEqual(
            EvalCapturePolicy.decide(
                enabled: false,
                secureInput: true,
                targetBundleID: nil,
                excludedBundleIDs: ["com.example.app"]
            ),
            .suppress(.disabled)
        )
        XCTAssertEqual(
            EvalCapturePolicy.decide(
                enabled: true,
                secureInput: true,
                targetBundleID: nil,
                excludedBundleIDs: []
            ),
            .suppress(.secureInput)
        )
        XCTAssertEqual(
            EvalCapturePolicy.decide(
                enabled: true,
                secureInput: false,
                targetBundleID: nil,
                excludedBundleIDs: []
            ),
            .suppress(.unknownTarget)
        )
        XCTAssertEqual(
            EvalCapturePolicy.decide(
                enabled: true,
                secureInput: false,
                targetBundleID: " Com.Example.App ",
                excludedBundleIDs: ["com.example.app"]
            ),
            .suppress(.excludedApp)
        )
        XCTAssertEqual(
            EvalCapturePolicy.decide(
                enabled: true,
                secureInput: false,
                targetBundleID: "com.example.clean",
                excludedBundleIDs: ["com.example.app"]
            ),
            .capture
        )
    }

    func testCaptureSanitizesReasonAndCounterLifecycle() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-capture-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvalStore(directory: root)
        EvalCapture.resetCountersForTesting()
        AppConfig.shared.evalModeEnabled = false

        record(reason: "disabled", secureInput: false, store: store)
        XCTAssertEqual(EvalCapture.suppressedCount, 0)

        AppConfig.shared.evalModeEnabled = true
        record(reason: nil, secureInput: true, store: store)
        XCTAssertEqual(EvalCapture.suppressedCount, 1)
        EvalCapture.resetSuppressedCount()
        XCTAssertEqual(EvalCapture.suppressedCount, 0)

        record(reason: "excludedApp(com.private.secret)", secureInput: false, store: store)
        XCTAssertEqual(store.entries.first?.reason, "excludedApp")
        XCTAssertFalse(store.entries.first?.reason?.contains("com.private.secret") == true)

        for index in store.count..<EvalStore.maximumEntries {
            XCTAssertTrue(store.append(EvalEntry(
                id: "capture-cap-\(index)",
                source: .dictation,
                appBundleID: "com.example.capture-test",
                original: "input",
                output: "input",
                outcome: .unchanged,
                reason: nil,
                elapsedMS: 1,
                abandoned: false
            )))
        }
        record(reason: nil, secureInput: false, store: store)
        XCTAssertEqual(EvalCapture.fullCount, 1)

        AppConfig.shared.evalModeEnabled = false
        XCTAssertEqual(EvalCapture.suppressedCount, 0)
        await store.waitForPendingIO()
    }

    private func record(reason: String?, secureInput: Bool, store: EvalStore) {
        EvalCapture.record(
            source: .dictation,
            appBundleID: "com.example.capture-test",
            original: "private input",
            output: "private input",
            outcome: .notPolished,
            reason: reason,
            elapsed: nil,
            abandoned: false,
            secureInput: secureInput,
            excludedBundleIDs: [],
            store: store
        )
    }
}
