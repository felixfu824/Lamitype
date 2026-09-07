import XCTest
@testable import HushType

final class DictationPolishStageTests: XCTestCase {
    func testSuccessChangedUsesPolishedText() async {
        let result = await DictationPolishStage.apply("raw") { _ in
            .success(polished: "polished", changed: true)
        }
        XCTAssertEqual(result.text, "polished")
        XCTAssertEqual(result.outcome, .polished(changed: true))
        XCTAssertGreaterThanOrEqual(result.elapsed, 0)
    }

    func testSuccessUnchangedPreservesOriginalBytes() async {
        let result = await DictationPolishStage.apply(" raw ") { _ in
            .success(polished: "raw", changed: false)
        }
        XCTAssertEqual(result.text, " raw ")
        XCTAssertEqual(result.outcome, .polished(changed: false))
    }

    func testEveryFailureKeepsRawWithStableToken() async {
        let failures: [(PolishError, String)] = [
            (.disabled, "disabled"),
            (.unavailable("reason"), "unavailable"),
            (.emptySelection, "empty"),
            (.codeDetected, "codeDetected"),
            (.generationFailed("reason"), "generationFailed"),
            (.timeout("reason"), "timeout"),
            (.emptyOutput, "emptyOutput"),
            (.lengthGuard, "lengthGuard"),
            (.scriptGuard, "scriptGuard"),
            (.mixGuard, "mixGuard"),
            (.refusalGuard, "refusalGuard"),
        ]
        for (error, token) in failures {
            let result = await DictationPolishStage.apply("private raw text") { _ in .failure(error) }
            XCTAssertEqual(result.text, "private raw text")
            XCTAssertEqual(result.outcome, .keptRaw(reason: token))
        }
    }

    func testWhitespaceDoesNotInvokePolisher() async {
        var calls = 0
        let result = await DictationPolishStage.apply(" \n ") { _ in
            calls += 1
            return .success(polished: "unexpected", changed: true)
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(result.text, " \n ")
        XCTAssertEqual(result.outcome, .keptRaw(reason: "empty"))
    }

    func testCallerReturnDeadlineDoesNotWaitForNonCooperativeWork() async {
        let start = Date()
        let result: String? = await TextPolisher.withCallerReturnDeadline(seconds: 0.05) {
            // Models a Foundation Models call that ignores cancellation: keep
            // sleeping regardless of the cancellation flag, without leaving a
            // never-resumed continuation behind in the test process.
            while true {
                try? await Task.sleep(nanoseconds: 20_000_000)
                if Date().timeIntervalSince(start) > 5 { return "late" }
            }
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
