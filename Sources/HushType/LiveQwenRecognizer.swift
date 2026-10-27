// Recognition math/prompt adapted verbatim from speech-swift Qwen3ASR.swift,
// revision d603472b11c21f5fb6492e9448a04ee669d0bf64 (Apache-2.0, Copyright 2025 Ivan Digital).
// See Resources/ThirdPartyLicenses/speech-swift.txt for the upstream license.
// Modified 2026-10-26 for atomic completion metadata in Lamitype.
// Only return metadata and failure handling differ. Batch Local keeps using upstream.
import Foundation
import MLX
import Qwen3ASR
import AudioCommon

struct LiveRecognition: Sendable {
    let text: String
    let generatedTokens: Int
    let endedByEOS: Bool
    var isComplete: Bool { endedByEOS }
}

enum LiveRecognitionError: LocalizedError {
    case unavailable, malformed, incomplete, empty
    var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.string("live.error.unavailable", fallback: "The local recognition model or tokenizer is unavailable.")
        case .malformed: return L10n.string("live.error.malformed", fallback: "Recognition returned an invalid result.")
        case .incomplete: return L10n.string("live.error.incomplete", fallback: "Recognition did not finish. The recording was kept for recovery.")
        case .empty: return L10n.string("live.error.empty", fallback: "No speech was recognized.")
        }
    }
}

/// Session-local successful-load cache; never retains the MLX model. Access
/// only from the serial inference queue so parsing cannot block a keyboard hook.
final class LiveSessionTokenizer {
    private let loader: () throws -> Qwen3Tokenizer
    private var cached: Qwen3Tokenizer?
    init(modelID: String) { loader = { try LiveQwenRecognizer.loadTokenizer(modelID: modelID) } }
    init(loader: @escaping () throws -> Qwen3Tokenizer) { self.loader = loader }
    func load() throws -> Qwen3Tokenizer {
        dispatchPrecondition(condition: .onQueue(LocalLiveInference.queue))
        if let cached { return cached }
        let value = try loader(); cached = value; return value
    }
}

/// Access only on LocalLiveInference.queue, while the experimental lease is held.
final class LiveQwenRecognizer {
    private let model: Qwen3ASRModel
    private let tokenizer: Qwen3Tokenizer
    private var audioEncoder: Qwen3AudioEncoder { model.audioEncoder }
    private var featureExtractor: WhisperFeatureExtractor { model.featureExtractor }
    private var textDecoder: QuantizedTextModel? { model.textDecoder }

    init(model: Qwen3ASRModel, tokenizer: Qwen3Tokenizer) {
        self.model = model; self.tokenizer = tokenizer
    }
    convenience init(model: Qwen3ASRModel, modelID: String) throws {
        self.init(model: model, tokenizer: try Self.loadTokenizer(modelID: modelID))
    }
    static func loadTokenizer(modelID: String) throws -> Qwen3Tokenizer {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qwen3-speech")
        let candidates = [root.appendingPathComponent("models").appendingPathComponent(modelID),
                          root.appendingPathComponent(Qwen3ASRModel.sanitizedCacheKey(for: modelID))]
        guard let directory = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("vocab.json").path)
        }) else { throw LiveRecognitionError.unavailable }
        let tokenizer = Qwen3Tokenizer()
        try tokenizer.load(from: directory.appendingPathComponent("vocab.json"))
        return tokenizer
    }
    func transcribe(
        audio: [Float],
        sampleRate: Int = 16000,
        language: String? = nil,
        maxTokens: Int = 448,
        context: String? = nil
    ) throws -> LiveRecognition {
        // Extract mel features
        let melFeatures = featureExtractor.process(audio, sampleRate: sampleRate)

        // Add batch dimension: [mel, time] -> [1, mel, time]
        let batchedFeatures = melFeatures.expandedDimensions(axis: 0)

        // Encode audio - returns [time, features] without batch dim (matching Python)
        var audioEmbeds = audioEncoder(batchedFeatures)

        // Add batch dimension for consistency: [time, features] -> [1, time, features]
        audioEmbeds = audioEmbeds.expandedDimensions(axis: 0)

        // Check if text decoder is loaded
        guard let textDecoder = textDecoder else {
            // Never turn a missing decoder into dictation text.
            throw LiveRecognitionError.unavailable
        }

        // Generate text using the text decoder
        return try generateText(
            audioEmbeds: audioEmbeds,
            textDecoder: textDecoder,
            language: language,
            maxTokens: maxTokens,
            context: context
        )
    }

    /// Generate text from audio embeddings
    func generateText(
        audioEmbeds: MLXArray,
        textDecoder: QuantizedTextModel,
        language: String?,
        maxTokens: Int,
        context: String? = nil
    ) throws -> LiveRecognition {
        // Special token IDs
        let imStartId = 151644
        let imEndId = 151645
        let audioStartId = 151669
        let audioEndId = 151670
        let audioPadId = 151676
        let asrTextId = 151704
        let newlineId = 198

        // Token IDs for "system", "user", "assistant"
        let systemId = 8948
        let userId = 872
        let assistantId = 77091

        // Number of audio tokens (from audio encoder output)
        let numAudioTokens = audioEmbeds.dim(1)

        // Build input_ids array with audio_pad placeholder tokens
        var inputIds: [Int32] = []

        // <|im_start|>system\n{context}<|im_end|>\n
        inputIds.append(contentsOf: [imStartId, systemId, newlineId].map { Int32($0) })
        if let context = context, !context.isEmpty {
            let contextTokens = tokenizer.encode(context)
            inputIds.append(contentsOf: contextTokens.map { Int32($0) })
        }
        inputIds.append(contentsOf: [imEndId, newlineId].map { Int32($0) })

        // <|im_start|>user\n<|audio_start|>
        inputIds.append(contentsOf: [imStartId, userId, newlineId, audioStartId].map { Int32($0) })

        // <|audio_pad|> * numAudioTokens (placeholder tokens that will be replaced)
        let audioStartIndex = inputIds.count
        for _ in 0..<numAudioTokens {
            inputIds.append(Int32(audioPadId))
        }
        let audioEndIndex = inputIds.count

        // <|audio_end|><|im_end|>\n
        inputIds.append(contentsOf: [audioEndId, imEndId, newlineId].map { Int32($0) })

        // <|im_start|>assistant\n
        inputIds.append(contentsOf: [imStartId, assistantId, newlineId].map { Int32($0) })

        // Add language hint if specified, then always add <|asr_text|> marker.
        // Without <|asr_text|>, the model doesn't know it should transcribe.
        // Without language hint, the model auto-detects and prepends "language XX" to output.
        if let lang = language {
            let langPrefix = "language \(lang)"
            let langTokens = tokenizer.encode(langPrefix)
            inputIds.append(contentsOf: langTokens.map { Int32($0) })
        }
        inputIds.append(Int32(asrTextId))

        // Get text embeddings for all tokens
        let inputIdsTensor = MLXArray(inputIds).expandedDimensions(axis: 0)
        var inputEmbeds = textDecoder.embedTokens(inputIdsTensor)

        // Replace audio_pad token positions with actual audio embeddings
        let audioEmbedsTyped = audioEmbeds.asType(inputEmbeds.dtype)
        let beforeAudio = inputEmbeds[0..., 0..<audioStartIndex, 0...]
        let afterAudio = inputEmbeds[0..., audioEndIndex..., 0...]

        inputEmbeds = concatenated([beforeAudio, audioEmbedsTyped, afterAudio], axis: 1)

        // Initialize KV cache
        var cache: [(MLXArray, MLXArray)]? = nil

        // Generate tokens
        var generatedTokens: [Int32] = []

        // First pass: process the full input embeddings
        var (hiddenStates, newCache) = textDecoder(inputsEmbeds: inputEmbeds, cache: cache)
        cache = newCache

        // Get logits from the last position using embedding as LM head (tied weights)
        let seqLen = hiddenStates.dim(1)
        let lastHidden = hiddenStates[0..., (seqLen-1)..<seqLen, 0...]
        var logits = textDecoder.embedTokens.asLinear(lastHidden)
        var nextToken = argMax(logits, axis: -1).squeezed().item(Int32.self)
        generatedTokens.append(nextToken)

        // Continue generating
        for _ in 1..<maxTokens {
            // Check for EOS
            if nextToken == Int32(Qwen3ASRTokens.eosTokenId) {
                break
            }

            // Get embedding for the new token
            let tokenEmbeds = textDecoder.embedTokens(MLXArray([nextToken]).expandedDimensions(axis: 0))

            // Forward pass with cache
            (hiddenStates, newCache) = textDecoder(inputsEmbeds: tokenEmbeds, cache: cache)
            cache = newCache

            // Get next token
            let lastHiddenNext = hiddenStates[0..., (-1)..., .ellipsis]
            logits = textDecoder.embedTokens.asLinear(lastHiddenNext)
            nextToken = argMax(logits, axis: -1).squeezed().item(Int32.self)
            generatedTokens.append(nextToken)
        }

        let rawText = tokenizer.decode(tokens: generatedTokens.map { Int($0) })
        let text: String
        if let range = rawText.range(of: "<asr_text>") {
            text = String(rawText[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else { text = rawText }
        guard !text.contains("<|"), !text.contains("<asr_") else {
            throw LiveRecognitionError.malformed
        }
        return LiveRecognition(text: text, generatedTokens: generatedTokens.count,
            endedByEOS: generatedTokens.last == Int32(Qwen3ASRTokens.eosTokenId))
    }
}
