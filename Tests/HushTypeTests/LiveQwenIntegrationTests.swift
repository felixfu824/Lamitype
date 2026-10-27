import AudioCommon
import MLX
import XCTest
@testable import HushType

final class LiveQwenIntegrationTests: XCTestCase {
    /// Actual cached model, archived synthetic and human regression audio, and shipping adapter.
    /// No new corpus download, API call or application preferences mutation.
    func testAdapterMatchesPinnedUpstreamAndReportsEOS() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LAMITYPE_LIVE_AUDIO_DIR"] else {
            throw XCTSkip("Set LAMITYPE_LIVE_AUDIO_DIR for offline MBA recognition integration")
        }
        let engine = Qwen3TranscriptionEngine()
        try await engine.load()
        defer { engine.unload() }
        let model = try XCTUnwrap(engine.loadedModel)
        let adapter = try LiveQwenRecognizer(model: model, modelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
        let root = URL(fileURLWithPath: directory)
        var fixtures = ["en_short.wav", "zh_short.wav", "mixed.wav"].map { root.appendingPathComponent($0) }
        let human = root.deletingLastPathComponent().appendingPathComponent("workbench/audio")
        for name in ["fleurs_en_001.wav", "fleurs_zh_094.wav", "ascend_mix_003.wav"] {
            let fixture = human.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: fixture.path) { fixtures.append(fixture) }
        }
        for fixture in fixtures {
            let name = fixture.lastPathComponent
            let samples = try AudioFileLoader.load(url: fixture, targetSampleRate: 16000)
            let result = try adapter.transcribe(audio: samples, language: nil, maxTokens: 1024)
            let baseline = model.transcribe(audio: samples, sampleRate: 16000, language: nil, maxTokens: 1024)
            XCTAssertEqual(result.text, baseline, name)
            XCTAssertTrue(result.endedByEOS, name)
            XCTAssertGreaterThan(result.generatedTokens, 0)
            XCTAssertFalse(result.text.isEmpty, name)
            print("PARITY fixture=\(name) samples=\(samples.count) tokens=\(result.generatedTokens) eos=\(result.endedByEOS) byteIdentical=\(result.text == baseline)")
        }
    }
    /// Explicit local diagnostic for exact captured samples; never runs in normal tests.
    func testExactFailedCaptureParityBeforeAndAfterDrafts() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAMITYPE_FAILED_CAPTURE_METADATA"] else {
            throw XCTSkip("Set LAMITYPE_FAILED_CAPTURE_METADATA for exact-sample diagnostic")
        }
        let metadataURL = URL(fileURLWithPath: path)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        let raw = try Data(contentsOf: metadataURL.deletingPathExtension().appendingPathExtension("f32"))
        XCTAssertEqual(raw.count % MemoryLayout<Float>.size, 0)
        let samples = raw.withUnsafeBytes { bytes in Array(bytes.bindMemory(to: Float.self)) }
        XCTAssertEqual(samples.count, metadata["samples"] as? Int)
        let language = metadata["language"] as? String
        let engine = Qwen3TranscriptionEngine(); try await engine.load(); defer { engine.unload() }
        let model = try XCTUnwrap(engine.loadedModel)
        let adapter = try LiveQwenRecognizer(model: model, modelID: try XCTUnwrap(metadata["modelID"] as? String))
        var rows: [[String: Any]] = []
        for round in 0..<2 {
            let before = try adapter.transcribe(audio: samples, language: language, maxTokens: 1024)
            let upstream = model.transcribe(audio: samples, sampleRate: 16000, language: language, maxTokens: 1024)
            XCTAssertEqual(before.text, upstream, "round \(round) before drafts")
            // Deterministic representative draft schedule at the same 2-second
            // cadence and 15-second blocks. This is not a claim to reproduce
            // every native scheduling instant or wall-clock IO interaction.
            for start in stride(from: 0, to: samples.count, by: 240_000) {
                for length in stride(from: 32_000, through: min(240_000, samples.count-start), by: 32_000) {
                    _ = try adapter.transcribe(audio: Array(samples[start..<(start+length)]), language: language, maxTokens: 1024)
                }
            }
            let after = try adapter.transcribe(audio: samples, language: language, maxTokens: 1024)
            let upstreamAfter = model.transcribe(audio: samples, sampleRate: 16000, language: language, maxTokens: 1024)
            XCTAssertEqual(after.text, upstreamAfter, "round \(round) after drafts")
            XCTAssertEqual(before.text, after.text, "draft-history determinism")
            XCTAssertEqual(before.generatedTokens, after.generatedTokens)
            XCTAssertEqual(before.endedByEOS, after.endedByEOS)
            rows.append(["round": round, "samples": samples.count, "tokens": before.generatedTokens,
                "endedByEOS": before.endedByEOS, "upstreamByteIdentical": before.text == upstream,
                "afterDraftsByteIdentical": after.text == upstreamAfter,
                "nativeTokens": metadata["generatedTokens"] ?? NSNull(),
                "nativeEndedByEOS": metadata["endedByEOS"] ?? NSNull(),
                "text": before.text, "afterDraftText": after.text])
        }
        let report = metadataURL.deletingPathExtension().appendingPathExtension("parity.json")
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: report)
    }

}
