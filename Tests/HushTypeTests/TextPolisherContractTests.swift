import Foundation
import XCTest

final class TextPolisherContractTests: XCTestCase {
    func testManualAndDictationPolishKeepDistinctToggleAndDeadlineContracts() throws {
        let source = try textPolisherSource()

        guard let manualStart = source.range(
            of: "static func polish(_ text: String) async -> PolishResult {"
        )?.lowerBound,
        let dictationStart = source.range(
            of: "static func polishDictation(_ text: String) async -> PolishResult {"
        )?.lowerBound,
        let implementationStart = source.range(
            of: "private static func polish("
        )?.lowerBound,
        let attemptStart = source.range(
            of: "private static func modelAttempt("
        )?.lowerBound,
        let budgetStart = source.range(
            of: "private static func remainingBudget("
        )?.lowerBound else {
            return XCTFail("TextPolisher source contract anchors are missing")
        }

        let manual = String(source[manualStart..<dictationStart])
        let dictation = String(source[dictationStart..<implementationStart])
        let implementation = String(source[implementationStart..<attemptStart])
        let attempt = String(source[attemptStart..<budgetStart])

        XCTAssertTrue(manual.contains("requiresManualToggle: true"))
        XCTAssertTrue(manual.contains("deadlineSeconds: 30"))
        XCTAssertTrue(implementation.contains(
            "if requiresManualToggle, !AppConfig.shared.textPolishEnabled"
        ))
        XCTAssertTrue(attempt.contains("if requiresManualToggle"))
        XCTAssertTrue(attempt.contains("withDeadline(seconds: deadlineSeconds, work)"))

        XCTAssertTrue(source.contains("static let dictationDeadlineSeconds: UInt64 = 8"))
        XCTAssertTrue(dictation.contains("requiresManualToggle: false"))
        XCTAssertTrue(dictation.contains("deadlineSeconds: dictationDeadlineSeconds"))
        XCTAssertTrue(dictation.contains("startedAt: Date()"))
        XCTAssertTrue(implementation.contains(
            "remainingBudget(deadlineSeconds: deadlineSeconds, startedAt: startedAt) < 1"
        ))
        XCTAssertTrue(attempt.contains(
            "let remaining = remainingBudget(deadlineSeconds: deadlineSeconds, startedAt: startedAt)"
        ))
        XCTAssertTrue(attempt.contains("withCallerReturnDeadline(seconds: remaining, work)"))
    }

    private func textPolisherSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HushType/TextPolisher.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
