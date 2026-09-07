import Foundation
import XCTest
@testable import HushType

final class EvalExportTests: XCTestCase {
    func testLabelMappingsAllowedKeysAndPrivacy() throws {
        let entries = [
            entry("a", outcome: .unchanged, label: .correct),
            entry("b", outcome: .polished, label: .correct),
            entry("c", outcome: .keptOriginal, label: .overEdited),
            entry(
                "d",
                outcome: .notPolished,
                label: .wrongOrMissed,
                reruns: [EvalRerun(
                    at: Date(timeIntervalSince1970: 1_700_000_100),
                    instructions: "Never add a period.",
                    output: "rerun-d",
                    outcome: .polished,
                    reason: nil,
                    elapsedMS: 22
                )]
            ),
            entry("e", outcome: .polished, label: nil),
            entry("e", outcome: .polished, label: nil)
        ]
        let files = try EvalExport.makeFiles(entries: entries, appVersion: "0.5.13")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: files.cases) as? [[String: Any]])
        XCTAssertEqual(cases.count, 5)
        XCTAssertEqual(cases[0]["expect"] as? String, "must_keep_verbatim")
        XCTAssertEqual(cases[1]["expect"] as? String, "must_change")
        XCTAssertEqual(cases[1]["expected_output"] as? String, "output-b")
        XCTAssertEqual(cases[2]["expect"] as? String, "must_keep_verbatim")
        XCTAssertTrue((cases[2]["rationale"] as? String)?.contains("output-c") == true)
        XCTAssertEqual(cases[3]["expect"] as? String, "judge")
        XCTAssertEqual(cases[4]["rationale"] as? String, "unlabelled")
        let allowed = Set(["id", "category", "input", "expect", "expected_output", "rationale"])
        XCTAssertTrue(cases.allSatisfy { Set($0.keys).isSubset(of: allowed) })
        XCTAssertFalse(String(decoding: files.cases, as: UTF8.self).contains("app_bundle_id"))

        let resultsText = String(decoding: files.results, as: UTF8.self)
        XCTAssertFalse(resultsText.contains("app_bundle_id"))
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: files.results) as? [String: Any])
        XCTAssertEqual(results["schema"] as? String, "lamitype-eval-results/1")
        let resultRows = try XCTUnwrap(results["results"] as? [[String: Any]])
        XCTAssertEqual(resultRows.count, 5)
        let notPolished = try XCTUnwrap(resultRows.first { $0["id"] as? String == "d" })
        XCTAssertTrue(notPolished["elapsed_ms"] is NSNull)
        let reruns = try XCTUnwrap(notPolished["reruns"] as? [[String: Any]])
        XCTAssertEqual(reruns.first?["instructions"] as? String, "Never add a period.")
        XCTAssertEqual(reruns.first?["output"] as? String, "rerun-d")
    }

    func testCallerFilterIsRespected() throws {
        let shown = [entry("shown", outcome: .polished, label: nil)]
        let files = try EvalExport.makeFiles(entries: shown, appVersion: "test")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: files.cases) as? [[String: Any]])
        XCTAssertEqual(cases.map { $0["id"] as? String }, ["shown"])
    }

    func testResultsPathUsesStemAndEqualURLsAreRejectedBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let casesURL = root.appendingPathComponent("renamed-by-user.json")
        let expectedResultsURL = root.appendingPathComponent("renamed-by-user-results.json")
        XCTAssertEqual(EvalExport.resultsURL(for: casesURL), expectedResultsURL)

        let files = try EvalExport.makeFiles(
            entries: [entry("path", outcome: .unchanged, label: .correct)],
            appVersion: "test"
        )
        XCTAssertThrowsError(try EvalExport.writeFiles(
            files,
            casesURL: casesURL,
            resultsURL: casesURL
        )) { error in
            guard let exportError = error as? EvalExport.ExportError,
                  case .sameOutputURL = exportError else {
                return XCTFail("Expected sameOutputURL, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: casesURL.path))

        XCTAssertEqual(try EvalExport.writeFiles(files, casesURL: casesURL), expectedResultsURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: casesURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedResultsURL.path))
    }

    private func entry(
        _ id: String,
        outcome: EvalOutcome,
        label: EvalLabel?,
        reruns: [EvalRerun] = []
    ) -> EvalEntry {
        EvalEntry(
            id: id,
            source: .polishHotkey,
            appBundleID: "com.private.app",
            original: "input-\(id)",
            output: "output-\(id)",
            outcome: outcome,
            reason: outcome == .polished ? nil : "disabled",
            elapsedMS: outcome == .notPolished ? nil : 10,
            abandoned: false,
            label: label,
            reruns: reruns
        )
    }
}
