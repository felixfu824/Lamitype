import XCTest
@testable import HushType

/// Env-gated evaluation harness for the Auto Polish prompt.
///
/// Runs the SHIPPED code path (`TextPolisher.polishDictation`) over an external
/// case file, twice in one process, and writes JSONL results. It is skipped in
/// the normal suite so CI and release gates are unaffected.
///
///     LAMITYPE_RUN_FM_EVAL=1 \
///     LAMITYPE_FM_EVAL_CASES=<abs path to cases.json> \
///     LAMITYPE_FM_EVAL_OUT=<abs path to results.jsonl> \
///     swift test --package-path <worktree> --filter FMPolishEvalTests
///
/// Pass N is written to `<out stem>_pass<N>.jsonl`.
final class FMPolishEvalTests: XCTestCase {

    private struct EvalCase: Decodable {
        let id: String
        let category: String
        let input: String
        let expect: String
    }

    private struct EvalRecord: Encodable {
        let id: String
        let category: String
        let pass: Int
        let outcome: String
        let changed: Bool
        let input: String
        let output: String
        let error_token: String
        let error_message: String
        let elapsed_ms: Int
    }

    func testRunFoundationModelsPolishEval() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LAMITYPE_RUN_FM_EVAL"] == "1" else {
            throw XCTSkip("Set LAMITYPE_RUN_FM_EVAL=1 to run the Foundation Models polish eval")
        }
        guard let casesPath = env["LAMITYPE_FM_EVAL_CASES"] else {
            throw XCTSkip("LAMITYPE_FM_EVAL_CASES is required (absolute path to cases.json)")
        }
        guard let outPath = env["LAMITYPE_FM_EVAL_OUT"] else {
            throw XCTSkip("LAMITYPE_FM_EVAL_OUT is required (absolute path to results.jsonl)")
        }

        let cases = try JSONDecoder().decode(
            [EvalCase].self,
            from: try Data(contentsOf: URL(fileURLWithPath: casesPath))
        )
        print("[FMEval] loaded \(cases.count) cases from \(casesPath)")

        // Mandatory: the app reads AppSupportPaths at launch preflight; without
        // an isolated root the process traps. Also guarantees no user
        // polish_rules.txt leaks into the prompt.
        let appSupportSandbox = try configureIsolatedAppSupport()
        defer {
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: appSupportSandbox)
        }

        // Optional full-prompt override, delivered through the shipped
        // `polish_prompt.txt` mechanism so `PolishPrompt.activePrompt()` and
        // `CleanupPromptOverride` behave exactly as they do in the app.
        if let promptFile = env["LAMITYPE_FM_EVAL_PROMPT_FILE"] {
            let dest = AppConfig.promptOverrideURL(filename: "polish_prompt.txt")
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: promptFile),
                to: dest
            )
            let active = PolishPrompt.activePrompt()
            print("[FMEval] prompt override from \(promptFile)")
            print("[FMEval] override active=\(active != PolishPrompt.systemPrompt) "
                + "chars=\(active.count) baked=\(PolishPrompt.systemPrompt.count) "
                + "fingerprint=\(active.hashValue)")
            XCTAssertNotEqual(active, PolishPrompt.systemPrompt, "prompt override was not picked up")
        } else {
            print("[FMEval] using the baked-in prompt, fingerprint=\(PolishPrompt.activePrompt().hashValue)")
        }

        await MainActor.run { TextPolisher.refreshAvailabilityCache() }
        guard TextPolisher.isAvailableCached else {
            throw XCTSkip(
                "Apple Foundation Models is unavailable on this Mac: \(TextPolisher.unavailableReasonCached)"
            )
        }

        // Mirror the app: one prewarmed standby session before the first polish.
        if #available(macOS 26.0, *) {
            await MainActor.run { FoundationModelsPolisher.warmup() }
        }
        defer {
            if #available(macOS 26.0, *) {
                Task { @MainActor in FoundationModelsPolisher.releaseSession() }
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        let passCount = Int(env["LAMITYPE_FM_EVAL_PASSES"] ?? "2") ?? 2
        for passIndex in 1...max(1, passCount) {
            let url = passOutputURL(base: outPath, pass: passIndex)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: url) else {
                XCTFail("Cannot open \(url.path) for writing")
                return
            }
            defer { try? handle.close() }

            let passStart = Date()
            for (index, testCase) in cases.enumerated() {
                let start = Date()
                let result = await TextPolisher.polishDictation(testCase.input)
                let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

                let record: EvalRecord
                switch result {
                case .success(let polished, let changed):
                    record = EvalRecord(
                        id: testCase.id,
                        category: testCase.category,
                        pass: passIndex,
                        outcome: "success",
                        changed: changed,
                        input: testCase.input,
                        output: polished,
                        error_token: "",
                        error_message: "",
                        elapsed_ms: elapsedMs
                    )
                case .failure(let error):
                    record = EvalRecord(
                        id: testCase.id,
                        category: testCase.category,
                        pass: passIndex,
                        outcome: "failure",
                        changed: false,
                        input: testCase.input,
                        output: "",
                        error_token: error.stableToken,
                        error_message: error.errorDescription ?? "",
                        elapsed_ms: elapsedMs
                    )
                }

                var line = try encoder.encode(record)
                line.append(0x0A)
                handle.write(line)

                let marker = record.outcome == "success"
                    ? (record.changed ? "CHANGED" : "verbatim")
                    : "FAIL:\(record.error_token)"
                print(
                    "[FMEval] p\(passIndex) \(index + 1)/\(cases.count) "
                        + "\(testCase.id) \(elapsedMs)ms \(marker)"
                )
                fflush(stdout)
            }
            let passSeconds = Int(Date().timeIntervalSince(passStart))
            print("[FMEval] pass \(passIndex) complete in \(passSeconds)s -> \(url.path)")
            fflush(stdout)
        }
    }

    /// Diagnostic only, gated on its own env var. Calls the FM layer with NO
    /// deadline to separate "slow" from "hung" for the cases that hit the 8 s
    /// dictation budget, and to surface raw framework errors.
    func testDiagnosticProbes() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LAMITYPE_FM_EVAL_PROBE"] == "1" else {
            throw XCTSkip("Set LAMITYPE_FM_EVAL_PROBE=1 to run the diagnostic probes")
        }
        let appSupportSandbox = try configureIsolatedAppSupport()
        defer {
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: appSupportSandbox)
        }
        await MainActor.run { TextPolisher.refreshAvailabilityCache() }
        guard TextPolisher.isAvailableCached, #available(macOS 26.0, *) else {
            throw XCTSkip("Apple Foundation Models is unavailable on this Mac")
        }

        let probes = [
            ("timeout_case", "我手機沒電了，你打我辦公室的分機好嗎？"),
            ("timeout_var_call", "我手機沒電了，你撥我辦公室的分機好嗎？"),
            ("timeout_var_noda", "我手機沒電了，你打辦公室的分機好嗎？"),
            ("timeout_var_short", "你打我辦公室的分機好嗎？"),
            ("unsafe_case", "I think the biggest risk is that the integration slips by another quarter."),
            ("unsafe_var_norisk", "I think the main issue is that the integration slips by another quarter."),
            ("unsafe_var_noslip", "I think the biggest risk is that the integration takes another quarter."),
            ("halluc_case", "我們下週在討論一次這個議題。"),
            ("halluc_var_nodate", "我們在討論一次這個議題。"),
        ]
        for (label, text) in probes {
            let start = Date()
            let result = await FoundationModelsPolisher.polish(text)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            switch result {
            case .success(let value):
                print("[FMProbe] \(label) \(ms)ms OK: \(value)")
            case .failure(let error):
                print("[FMProbe] \(label) \(ms)ms ERR: \(error)")
            }
            fflush(stdout)
        }
    }

    private func passOutputURL(base: String, pass: Int) -> URL {
        let url = URL(fileURLWithPath: base)
        let ext = url.pathExtension.isEmpty ? "jsonl" : url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        return url
            .deletingLastPathComponent()
            .appendingPathComponent("\(stem)_pass\(pass)")
            .appendingPathExtension(ext)
    }

    /// Copied verbatim from AutoPolishLiveTests: without this the process traps
    /// with "AppSupportPaths read before launch preflight".
    private func configureIsolatedAppSupport() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lamitype-fm-polish-eval-\(UUID().uuidString)",
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
