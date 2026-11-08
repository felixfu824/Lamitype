import AVFoundation
import XCTest
@testable import HushType

/// Opt-in: switches a loaded engine Fast → Optimized → Fast with real weights
/// and transcribes a real recording after each switch.
///
///     LAMITYPE_RUN_ASR_INTEGRATION=1 \
///     LAMITYPE_OPTIMIZED_MODEL_PATH=<local Optimized model folder> \
///     LAMITYPE_SWITCH_TEST_WAV=<16 kHz mono wav> \
///     swift test --disable-sandbox --filter LocalModelSwitchIntegrationTests
final class LocalModelSwitchIntegrationTests: XCTestCase {
    func testSwitchBothWaysWithRealWeights() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LAMITYPE_RUN_ASR_INTEGRATION"] == "1",
              let optimized = env["LAMITYPE_OPTIMIZED_MODEL_PATH"],
              let wav = env["LAMITYPE_SWITCH_TEST_WAV"] else {
            throw XCTSkip("Set LAMITYPE_RUN_ASR_INTEGRATION=1, LAMITYPE_OPTIMIZED_MODEL_PATH and LAMITYPE_SWITCH_TEST_WAV")
        }
        let fast = AppConfig.LocalModel.fast.huggingFaceID
        guard LocalModelSwitcher.weightsOnDisk(source: fast), LocalModelSwitcher.weightsOnDisk(source: optimized) else {
            throw XCTSkip("Both models must be on disk; refusing to download")
        }
        guard try installMetallib() else { throw XCTSkip("mlx.metallib is unavailable") }
        setenv("HF_ENDPOINT", "http://127.0.0.1:9", 1)

        let key = "hushtype.modelId"
        let saved = UserDefaults.standard.object(forKey: key)
        AppConfig.shared.modelId = fast
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let audio = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

        let engine = Qwen3TranscriptionEngine()
        try await engine.load()
        defer { engine.unload() }
        XCTAssertEqual(engine.loadedModelID, fast)
        let first = try XCTUnwrap(engine.loadedModel)
        let fastText = first.transcribe(audio: audio, sampleRate: 16000, language: nil)

        try await engine.switchModel(to: optimized)
        XCTAssertEqual(engine.loadedModelID, optimized)
        let second = try XCTUnwrap(engine.loadedModel)
        XCTAssertFalse(first === second)
        let optimizedText = second.transcribe(audio: audio, sampleRate: 16000, language: nil)

        try await engine.switchModel(to: fast)
        XCTAssertEqual(engine.loadedModelID, fast)
        let backText = try XCTUnwrap(engine.loadedModel).transcribe(audio: audio, sampleRate: 16000, language: nil)

        print("SWITCH fast=\(fastText) | optimized=\(optimizedText) | back=\(backText)")
        XCTAssertFalse(fastText.isEmpty)
        XCTAssertFalse(optimizedText.isEmpty)
        XCTAssertEqual(backText, fastText, "Switching back must restore the Fast output exactly")

        // A failed switch keeps the current model.
        do {
            try await engine.switchModel(to: FileManager.default.temporaryDirectory.appendingPathComponent("no-model-\(UUID().uuidString)").path)
            XCTFail("Expected the switch to a missing folder to fail")
        } catch {}
        XCTAssertEqual(engine.loadedModelID, fast)
        XCTAssertNotNil(engine.loadedModel)
    }

    private func installMetallib() throws -> Bool {
        let fm = FileManager.default
        guard let dir = Bundle(for: Self.self).executableURL?.deletingLastPathComponent() else { return false }
        let destination = dir.appendingPathComponent("mlx.metallib")
        if fm.fileExists(atPath: destination.path) { return true }
        let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let candidates = [root.appendingPathComponent(".build/debug/mlx.metallib"),
                          root.appendingPathComponent(".build/release/mlx.metallib"),
                          URL(fileURLWithPath: "/Applications/Lamitype.app/Contents/MacOS/mlx.metallib")]
        guard let source = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { return false }
        try fm.copyItem(at: source, to: destination)
        return true
    }
}
