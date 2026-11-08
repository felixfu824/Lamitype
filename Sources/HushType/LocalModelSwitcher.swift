import AudioCommon
import Foundation
import MLX
import Qwen3ASR
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "local-model")

extension Notification.Name {
    static let lamitypeLocalModelDidChange = Notification.Name("com.felix.hushtype.localModelDidChange")
}

/// Owns the Fast / Optimized choice for Settings and the menu bar.
///
/// A switch loads the new model beside the current one (downloading it first
/// when it is not on disk) and swaps only after the load succeeds, so a
/// cancelled or failed switch leaves the current model in use. The saved
/// choice changes only on success.
@MainActor
final class LocalModelSwitcher: ObservableObject {
    static let shared = LocalModelSwitcher()

    enum Phase: Equatable {
        case idle
        case switching(to: AppConfig.LocalModel, downloading: Bool, progress: Double)
        case failed(AppConfig.LocalModel)
        case loadFailed(AppConfig.LocalModel)
    }

    @Published private(set) var active: AppConfig.LocalModel
    @Published private(set) var phase: Phase = .idle {
        didSet { NotificationCenter.default.post(name: .lamitypeLocalModelDidChange, object: self) }
    }

    /// Wired by AppDelegate at launch.
    var engine: Qwen3TranscriptionEngine?
    var hasLoadedModel: ((Qwen3TranscriptionEngine) -> Bool)?
    var loadInFlight: ((Qwen3TranscriptionEngine) -> Bool)?
    /// True while recording, transcribing, Live preview or Live Caption runs.
    var isBusy: () -> Bool = { false }

    private let config: AppConfig
    private var task: Task<Void, Never>?
    private var previousTask: Task<Void, Never>?
    private var downloadCompleted = false
    private var switchID = 0
    private(set) var gateClosed = false
    var download: (String, @escaping (Double) -> Void) async throws -> Void = { source, progress in
        guard !source.hasPrefix("/") && !source.hasPrefix("~") else { return }
        let cache = try HuggingFaceDownloader.getCacheDirectory(for: source)
        try await HuggingFaceDownloader.downloadWeights(
            modelId: source, to: cache,
            additionalFiles: ["vocab.json", "merges.txt", "tokenizer_config.json"],
            progressHandler: { fraction in progress(fraction) })
    }
    var loadAndSwap: ((Qwen3TranscriptionEngine, String) async throws -> Void)?
    var gateTimeoutNanoseconds: UInt64 = 60_000_000_000

    init(config: AppConfig = .shared) {
        self.config = config
        active = config.localModel
    }

    var isSwitching: Bool {
        if case .switching = phase { return true }
        return false
    }

    var refusesLocalRequests: Bool { gateClosed }

    /// The model the picker shows as chosen: the switch target while one runs.
    var shownSelection: AppConfig.LocalModel {
        if case .switching(let target, _, _) = phase { return target }
        return active
    }

    func isOnDisk(_ model: AppConfig.LocalModel) -> Bool {
        Self.weightsOnDisk(source: config.modelSource(for: model))
    }

    /// Starts a switch. Returns false when it cannot start now because the
    /// app is busy or another switch is running.
    @discardableResult
    func select(_ model: AppConfig.LocalModel) -> Bool {
        guard !isSwitching else { return false }
        guard engine.map({ loadInFlight?($0) ?? $0.hasInFlightLoad }) != true else { return false }
        if model == active {
            if case .failed = phase { phase = .idle }
            if case .loadFailed = phase { phase = .idle }
            // After a launch fallback the saved choice can differ from the
            // model in use; choosing the model in use saves it.
            if config.localModel != model { commit(model) }
            return true
        }
        guard !isBusy() else { return false }
        guard let engine, hasLoadedModel?(engine) ?? engine.isLoaded else {
            // Nothing is loaded (unloaded, or a cloud engine): the next load uses the choice.
            commit(model)
            phase = .idle
            return true
        }

        switchID += 1
        let id = switchID
        let source = config.modelSource(for: model)
        let priorTask = previousTask
        downloadCompleted = false
        phase = .switching(to: model, downloading: !isOnDisk(model), progress: 0)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if let priorTask { await priorTask.value }
                try Task.checkCancellation()
                try await self.download(source) { progress in
                    Task { @MainActor in self.updateProgress(progress * 0.8, id: id) }
                }
                try Task.checkCancellation()
                self.downloadCompleted = true
                self.phase = .switching(to: model, downloading: false, progress: 0.8)
                while self.isBusy() {
                    if !self.waitingForIdle {
                        self.waitingForIdle = true
                        self.phase = .switching(to: model, downloading: false, progress: 0.8)
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                // MainActor owns both the idle test and gate close. No entry
                // point can start a local session between these statements.
                try Task.checkCancellation()
                self.gateClosed = true
                self.waitingForIdle = false
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: self?.gateTimeoutNanoseconds ?? 60_000_000_000) }
                    catch { return }
                    guard let self, id == self.switchID, self.gateClosed else { return }
                    self.cancelForTimeout(model, id: id)
                }
                defer { timeout.cancel(); self.gateClosed = false }
                if let loadAndSwap = self.loadAndSwap {
                    try await loadAndSwap(engine, source)
                } else {
                    try await engine.switchModel(to: source)
                }
                try Task.checkCancellation()
                self.finish(model, id: id)
            } catch Qwen3TranscriptionEngine.SwitchError.notLoaded {
                guard id == self.switchID else { return }
                self.commit(model)
                self.phase = .idle
            } catch is CancellationError {
                guard id == self.switchID else { return }
                self.phase = .idle
            } catch Qwen3TranscriptionEngine.SwitchError.busy {
                guard id == self.switchID else { return }
                self.phase = .idle
            } catch {
                log.error("Model switch failed: \(error.localizedDescription, privacy: .public)")
                guard id == self.switchID else { return }
                self.phase = self.downloadCompleted ? .loadFailed(model) : .failed(model)
            }
        }
        return true
    }

    func cancel() {
        guard isSwitching else { return }
        switchID += 1
        previousTask = task
        task?.cancel()
        task = nil
        gateClosed = false
        waitingForIdle = false
        phase = .idle
    }

    @Published private(set) var waitingForIdle = false

    private func cancelForTimeout(_ model: AppConfig.LocalModel, id: Int) {
        guard id == switchID else { return }
        switchID += 1
        task?.cancel()
        task = nil
        gateClosed = false
        waitingForIdle = false
        phase = .loadFailed(model)
    }

    /// Percentage of the download, or nil once loading has started.
    /// speech-swift reports download as 0-0.8 of overall progress.
    var downloadPercent: Int? {
        guard case .switching(_, true, let progress) = phase, progress < 0.8 else { return nil }
        return min(99, Int(progress / 0.8 * 100))
    }

    /// Menu bar status line text while a switch runs or after it failed.
    var statusText: String? {
        switch phase {
        case .idle:
            return nil
        case .switching:
            if waitingForIdle {
                return L10n.string("status.model.waiting", fallback: "Waiting for dictation to finish…")
            }
            if let percent = downloadPercent {
                return L10n.format("status.model.downloading", "Downloading model… %1$ld%%", arguments: [percent])
            }
            return L10n.string("status.model.switching", fallback: "Switching model…")
        case .failed:
            return L10n.string("status.model.download_failed", fallback: "Couldn’t download model")
        case .loadFailed:
            return L10n.string("status.model.load_failed", fallback: "Couldn’t load model")
        }
    }

    /// The saved model failed to load and `fallback` loaded instead. Shows
    /// the failure with Try Again; the saved choice is kept, so the next
    /// launch tries the saved model again.
    func noteLoadFallback(failed: AppConfig.LocalModel, using fallback: AppConfig.LocalModel) {
        guard !isSwitching else { return }
        active = fallback
        phase = .loadFailed(failed)
    }

    #if DEBUG
    /// Test hook for rendering each state.
    func setPhaseForTesting(_ phase: Phase) { self.phase = phase }
    #endif

    private func updateProgress(_ progress: Double, id: Int) {
        guard id == switchID, case .switching(let target, let downloading, _) = phase else { return }
        phase = .switching(to: target, downloading: downloading, progress: progress)
    }

    private func finish(_ model: AppConfig.LocalModel, id: Int) {
        guard id == switchID else { return }
        commit(model)
        phase = .idle
        // Return the previous model's buffers to the OS.
        MLX.Memory.clearCache()
    }

    private func commit(_ model: AppConfig.LocalModel) {
        config.localModel = model
        active = model
    }

    /// True when the model's weights are on disk: a local folder, or the
    /// speech-swift cache (flat or Hub-style layout).
    nonisolated static func weightsOnDisk(source: String) -> Bool {
        if source.hasPrefix("/") || source.hasPrefix("~") {
            let folder = URL(fileURLWithPath: (source as NSString).expandingTildeInPath, isDirectory: true)
            return HuggingFaceDownloader.weightsExist(in: folder)
        }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return false
        }
        let base = caches.appendingPathComponent("qwen3-speech", isDirectory: true)
        var candidates = [base.appendingPathComponent(Qwen3ASRModel.sanitizedCacheKey(for: source), isDirectory: true)]
        let parts = source.split(separator: "/").map(String.init)
        if parts.count == 2 {
            candidates.append(base.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(parts[0], isDirectory: true)
                .appendingPathComponent(parts[1], isDirectory: true))
        }
        return candidates.contains { HuggingFaceDownloader.weightsExist(in: $0) }
    }
}

extension AppConfig.LocalModel {
    var displayName: String {
        switch self {
        case .fast: return L10n.string("local_model.fast", fallback: "Fast (4-bit)")
        case .optimized: return L10n.string("local_model.optimized", fallback: "Optimized (6/8-bit)")
        }
    }
}
