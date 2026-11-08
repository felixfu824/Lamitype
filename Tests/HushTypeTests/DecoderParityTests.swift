import AVFoundation
import MLX
import Qwen3ASR
import XCTest
@testable import HushType

/// Opt-in: Standard (speech-swift `transcribe`) and Live (`LiveQwenRecognizer`)
/// must give the same raw text for the same audio and the same token limit.
/// The two paths keep their own tuned limits in the app; this test holds the
/// limit equal so it guards only the shared prompt and decoding code.
///
///     LAMITYPE_RUN_DECODER_PARITY=1 \
///     LAMITYPE_PARITY_CLIPS=<folder of 16 kHz mono .wav files> \
///     [LAMITYPE_OPTIMIZED_MODEL_PATH=<local Optimized model folder>] \
///     swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --disable-sandbox --filter DecoderParityTests
final class DecoderParityTests: XCTestCase {
    private static let tokenLimit = 1024
    private static let languages: [String?] = [nil, "chinese", "english"]

    func testStandardAndLiveGiveTheSameText() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LAMITYPE_RUN_DECODER_PARITY"] == "1", let folder = env["LAMITYPE_PARITY_CLIPS"] else {
            throw XCTSkip("Set LAMITYPE_RUN_DECODER_PARITY=1 and LAMITYPE_PARITY_CLIPS")
        }
        let clips = try FileManager.default.contentsOfDirectory(atPath: folder)
            .filter { $0.hasSuffix(".wav") }.sorted()
            .map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        XCTAssertFalse(clips.isEmpty, "No .wav files in \(folder)")

        var models = [AppConfig.LocalModel.fast.huggingFaceID]
        if let optimized = env["LAMITYPE_OPTIMIZED_MODEL_PATH"] { models.append(optimized) }
        for model in models where !LocalModelSwitcher.weightsOnDisk(source: model) {
            throw XCTSkip("\(model) is not on disk; refusing to download")
        }
        guard try installMetallib() else { throw XCTSkip("mlx.metallib is unavailable") }
        setenv("HF_ENDPOINT", "http://127.0.0.1:9", 1)
        MLX.Memory.cacheLimit = 1024 * 1024 * 1024 // the app's cap

        let key = "hushtype.modelId"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }

        var compared = 0
        for modelID in models {
            AppConfig.shared.modelId = modelID
            let engine = Qwen3TranscriptionEngine()
            try await engine.load()
            defer { engine.unload() }
            let model = try XCTUnwrap(engine.loadedModel)
            // Same tokenizer lookup and inference queue the app uses for Live.
            let recognizer = LiveQwenRecognizer(model: model, tokenizer: try LiveQwenRecognizer.loadTokenizer(modelID: modelID))

            for clip in clips {
                let audio = try load16kMono(clip)
                for language in Self.languages {
                    let standard = model.transcribe(audio: audio, sampleRate: 16000, language: language, maxTokens: Self.tokenLimit)
                    let live = try await LocalLiveInference.run {
                        try recognizer.transcribe(audio: audio, language: language, maxTokens: Self.tokenLimit)
                    }
                    XCTAssertEqual(live.text, standard,
                                   "\(modelID.split(separator: "/").last ?? "") \(clip.lastPathComponent) language=\(language ?? "auto")")
                    compared += 1
                }
            }
        }
        print("DecoderParity compared=\(compared)")
    }

    private func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        if source.sampleRate == 16000 && source.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength)))
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target))
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / source.sampleRate)) + 256
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    private func installMetallib() throws -> Bool {
        let fm = FileManager.default
        guard let dir = Bundle(for: Self.self).executableURL?.deletingLastPathComponent() else { return false }
        let destination = dir.appendingPathComponent("mlx.metallib")
        if fm.fileExists(atPath: destination.path) { return true }
        let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let candidates = [root.appendingPathComponent(".build-rel/release/mlx.metallib"),
                          root.appendingPathComponent(".build/release/mlx.metallib"),
                          root.appendingPathComponent(".build/debug/mlx.metallib")]
        guard let source = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { return false }
        try fm.copyItem(at: source, to: destination)
        return true
    }
}
