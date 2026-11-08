import Foundation
import Qwen3ASR
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "transcription")

// MARK: - Protocol

protocol TranscriptionEngine: AnyObject {
    var isLoaded: Bool { get }
    var maxSampleCount: Int? { get }
    func load(progressHandler: ((Double, String) -> Void)?) async throws
    func transcribe(audio: [Float], language: String?) async throws -> String
}

extension TranscriptionEngine {
    var maxSampleCount: Int? { nil }
}

enum TranscriptionError: Error, Equatable, Sendable {
    case noKey
    case auth
    case permissionDenied(provider: String)
    case rateLimited(provider: String)
    case network
    case timeout
    case payloadTooLarge
    case malformedResponse
    case safetyBlocked
}

// MARK: - Qwen3 Implementation

/// Model pointer and generation, accessed only while the engine load lock is held.
/// Kept generic so shared-load races can be tested without model weights.
final class SharedModelCommitState<Model: AnyObject> {
    private(set) var model: Model?
    private(set) var generation: UInt = 0

    func acceptLoad(_ loaded: Model, generation: UInt) -> Bool {
        guard generation == self.generation,
              model == nil || model === loaded else { return false }
        model = loaded
        return true
    }

    func swap(_ loaded: Model, generation: UInt) -> Bool {
        guard generation == self.generation, model != nil else { return false }
        model = loaded
        self.generation &+= 1
        return true
    }

    func unload() {
        model = nil
        generation &+= 1
    }

    func fencePendingSwitch() {
        generation &+= 1
    }
}

final class Qwen3TranscriptionEngine: TranscriptionEngine {
    private let loadLock = NSLock()
    private let commits = SharedModelCommitState<Qwen3ASRModel>()
    private var model: Qwen3ASRModel? { commits.model }
    private var loadGeneration: UInt { commits.generation }
    private var inFlightLoad: Task<Qwen3ASRModel, Error>?
    private var inFlightGeneration: UInt = 0
    private var progressHandlers: [UUID: (Double, String) -> Void] = [:]
    private var latestProgress: (Double, String)?
    private var currentModelID: String?
    private var inFlightModelID: String?
    private var switching = false

    private struct PreparedLoad {
        let task: Task<Qwen3ASRModel, Error>
        let generation: UInt
        let replayProgress: (Double, String)?
    }

    var isLoaded: Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        return model != nil
    }

    var hasInFlightLoad: Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        return inFlightLoad != nil
    }

    /// Read-only handle for the live-caption pipeline. Returns the loaded
    /// model instance so `LiveCaptionManager` can call `transcribe()` directly
    /// without going through the dictation post-processing chain.
    var loadedModel: Qwen3ASRModel? {
        loadLock.lock()
        defer { loadLock.unlock() }
        return model
    }

    /// Model ID or local folder of the loaded model; nil while unloaded.
    var loadedModelID: String? {
        loadLock.lock()
        defer { loadLock.unlock() }
        return model == nil ? nil : currentModelID
    }

    enum SwitchError: Error, Equatable {
        case notLoaded
        case busy
    }

    /// Loads `modelID` beside the current model and swaps it in only after
    /// the load succeeds, so dictation keeps the current model meanwhile and
    /// a failed or cancelled load leaves it in place. Unloading during the
    /// switch cancels it.
    func switchModel(
        to modelID: String,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        let generation = try beginSwitch()
        defer { endSwitch() }
        log.info("Switching model to: \(modelID)")
        let newModel = try await Qwen3ASRModel.fromPretrained(
            modelId: modelID,
            progressHandler: progressHandler
        )
        try Task.checkCancellation()
        guard commitSwitch(newModel, modelID: modelID, generation: generation) else {
            throw CancellationError()
        }
        log.info("Model switched")
    }

    private func beginSwitch() throws -> UInt {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard model != nil else { throw SwitchError.notLoaded }
        guard inFlightLoad == nil, !switching else { throw SwitchError.busy }
        switching = true
        return loadGeneration
    }

    private func endSwitch() {
        loadLock.lock()
        switching = false
        loadLock.unlock()
    }

    private func commitSwitch(_ newModel: Qwen3ASRModel, modelID: String, generation: UInt) -> Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard commits.swap(newModel, generation: generation) else { return false }
        currentModelID = modelID
        return true
    }

    /// Linearizes cancellation with the model commit under the same lock.
    /// If commit won, return its ID; otherwise the epoch prevents a late commit.
    func fencePendingSwitchAndGetModelID() -> String? {
        loadLock.lock()
        defer { loadLock.unlock() }
        commits.fencePendingSwitch()
        return model == nil ? nil : currentModelID
    }

    func load(progressHandler: ((Double, String) -> Void)? = nil) async throws {
        try await load(modelID: nil, progressHandler: progressHandler)
    }

    /// Loads the saved model. When it fails and `fallbackModelID` is set,
    /// loads that model instead. Returns true when the fallback loaded.
    @discardableResult
    func load(
        fallbackModelID: String?,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> Bool {
        do {
            try await load(modelID: nil, progressHandler: progressHandler)
            return false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let fallbackModelID else { throw error }
            log.error("Saved model failed to load (\(error.localizedDescription, privacy: .public)); loading fallback")
            try await load(modelID: fallbackModelID, progressHandler: progressHandler)
            return true
        }
    }

    /// Loads `modelID`, or the saved model when nil.
    private func load(modelID: String?, progressHandler: ((Double, String) -> Void)?) async throws {
        let handlerID = progressHandler.map { _ in UUID() }
        guard let prepared = prepareLoad(
            modelID: modelID,
            handlerID: handlerID,
            progressHandler: progressHandler
        ) else { return }

        if let replayProgress = prepared.replayProgress, let progressHandler {
            progressHandler(replayProgress.0, replayProgress.1)
        }

        do {
            let loadedModel = try await prepared.task.value
            guard commitLoadedModel(
                loadedModel,
                generation: prepared.generation,
                handlerID: handlerID
            ) else {
                throw CancellationError()
            }
            log.info("Model loaded successfully")
        } catch {
            finishFailedLoad(generation: prepared.generation, handlerID: handlerID)
            throw error
        }
    }

    /// Keep NSLock acquisition in a synchronous helper. Swift warns against
    /// directly holding even a short-lived mutex in an async function because
    /// suspension while locked would deadlock; this helper cannot suspend.
    private func prepareLoad(
        modelID: String?,
        handlerID: UUID?,
        progressHandler: ((Double, String) -> Void)?
    ) -> PreparedLoad? {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard model == nil else { return nil }

        if let handlerID, let progressHandler {
            progressHandlers[handlerID] = progressHandler
        }
        let replayProgress = latestProgress

        if let existing = inFlightLoad {
            return PreparedLoad(
                task: existing,
                generation: inFlightGeneration,
                replayProgress: replayProgress
            )
        }

        let modelId = modelID ?? AppConfig.shared.modelId
        let generation = loadGeneration
        inFlightGeneration = generation
        inFlightModelID = modelId
        log.info("Loading model: \(modelId)")
        let task = Task { [weak self] in
            try await Qwen3ASRModel.fromPretrained(
                modelId: modelId,
                progressHandler: { progress, description in
                    self?.publishLoadProgress(
                        progress,
                        description: description,
                        generation: generation
                    )
                }
            )
        }
        inFlightLoad = task
        return PreparedLoad(task: task, generation: generation, replayProgress: replayProgress)
    }

    private func commitLoadedModel(
        _ loadedModel: Qwen3ASRModel,
        generation: UInt,
        handlerID: UUID?
    ) -> Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard commits.acceptLoad(loadedModel, generation: generation) else {
            if let handlerID { progressHandlers.removeValue(forKey: handlerID) }
            return false
        }
        currentModelID = inFlightModelID
        if inFlightLoad != nil && inFlightGeneration == generation {
            inFlightLoad = nil
            progressHandlers.removeAll()
            latestProgress = nil
        } else if let handlerID {
            progressHandlers.removeValue(forKey: handlerID)
        }
        return true
    }

    private func finishFailedLoad(generation: UInt, handlerID: UUID?) {
        loadLock.lock()
        defer { loadLock.unlock() }
        if inFlightLoad != nil && inFlightGeneration == generation {
            inFlightLoad = nil
            progressHandlers.removeAll()
            latestProgress = nil
        } else if let handlerID {
            progressHandlers.removeValue(forKey: handlerID)
        }
    }

    private func publishLoadProgress(
        _ progress: Double,
        description: String,
        generation: UInt
    ) {
        loadLock.lock()
        guard inFlightLoad != nil && inFlightGeneration == generation else {
            loadLock.unlock()
            return
        }
        latestProgress = (progress, description)
        let handlers = Array(progressHandlers.values)
        loadLock.unlock()
        for handler in handlers {
            handler(progress, description)
        }
    }

    func transcribe(audio: [Float], language: String?) async throws -> String {
        guard let model = loadedModel else {
            log.error("Model not loaded")
            return ""
        }

        guard !audio.isEmpty else {
            log.warning("Empty audio buffer")
            return ""
        }

        let duration = Double(audio.count) / 16000.0
        log.info("Transcribing \(String(format: "%.1f", duration))s of audio...")

        let startTime = CFAbsoluteTimeGetCurrent()

        let rawText = model.transcribe(
            audio: audio,
            sampleRate: 16000,
            language: language
        )

        let asrElapsed = CFAbsoluteTimeGetCurrent() - startTime
        log.info("Raw transcription (\(String(format: "%.2f", asrElapsed))s): \(rawText)")

        let finalText = DictationPostProcessor.apply(rawText)

        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        let inCh = rawText.count
        let outCh = finalText.count
        let asrMs = Int(asrElapsed * 1000)
        let totalMs = Int(totalElapsed * 1000)

        log.info("timings asr=\(asrMs, privacy: .public)ms total=\(totalMs, privacy: .public)ms in=\(inCh, privacy: .public)ch out=\(outCh, privacy: .public)ch")

        return finalText
    }

    func unload() {
        loadLock.lock()
        commits.unload()
        inFlightLoad?.cancel()
        inFlightLoad = nil
        progressHandlers.removeAll()
        latestProgress = nil
        loadLock.unlock()
        log.info("Model unloaded")
    }
}
