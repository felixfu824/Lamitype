import AudioCommon
import CryptoKit
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
        /// The saved model failed to load at launch or reload and no model
        /// is loaded (no fallback was used).
        case notLoaded(AppConfig.LocalModel)
    }

    @Published private(set) var active: AppConfig.LocalModel
    @Published private(set) var phase: Phase = .idle {
        didSet { NotificationCenter.default.post(name: .lamitypeLocalModelDidChange, object: self) }
    }

    /// Wired by AppDelegate at launch.
    var engine: Qwen3TranscriptionEngine?
    var hasLoadedModel: ((Qwen3TranscriptionEngine) -> Bool)?
    var loadInFlight: ((Qwen3TranscriptionEngine) -> Bool)?
    var loadedModelID: ((Qwen3TranscriptionEngine) -> String?)?
    var fenceEngineSwitch: ((Qwen3TranscriptionEngine) -> String?)?
    /// True while recording, transcribing, Live preview or Live Caption runs.
    var isBusy: () -> Bool = { false }
    /// Reloads the saved model after a load left nothing loaded. Wired by AppDelegate.
    var retryLoad: (() -> Void)?
    /// A retry loads the local model, so it runs only while Local dictation is selected.
    var canRetryLoad: () -> Bool = { true }

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
    var cacheRoot: () -> URL = { LocalModelSwitcher.configuredCacheRoot() }
    var cacheDirectories: (String, URL) -> [URL] = { LocalModelSwitcher.remoteCacheDirectories(for: $0, root: $1) }
    var cacheIsValid: @Sendable (URL) -> Bool = { LocalModelSwitcher.validCachedWeights(in: $0) }
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
            if case .notLoaded = phase {
                guard !isBusy(), canRetryLoad() else { return false }
                phase = .idle
                if config.localModel != model { commit(model) }
                retryLoad?()
                return true
            }
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
            // After a failed load, load the new choice now.
            let retryAfterFailure: Bool
            if case .notLoaded = phase { retryAfterFailure = canRetryLoad() } else { retryAfterFailure = false }
            commit(model)
            phase = .idle
            if retryAfterFailure { retryLoad?() }
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
                if !source.hasPrefix("/") && !source.hasPrefix("~"),
                   engine.loadedModelID != source {
                    let root = self.cacheRoot()
                    let paths = self.cacheDirectories(source, root)
                    let validate = self.cacheIsValid
                    let invalid = await Task.detached(priority: .utility) {
                        paths.filter { FileManager.default.fileExists(atPath: $0.path) && !validate($0) }
                    }.value
                    try Task.checkCancellation()
                    for path in invalid {
                        try Task.checkCancellation()
                        guard id == self.switchID, self.readEngineModelID() != source else {
                            throw CancellationError()
                        }
                        guard Self.isSafeTargetCache(path, source: source, root: root) else {
                            throw CacheRepairError.unsafeCachePath
                        }
                        try FileManager.default.removeItem(at: path)
                    }
                }
                try Task.checkCancellation()
                try await self.download(source) { progress in
                    Task { @MainActor in self.updateProgress(progress * 0.8, id: id) }
                }
                try Task.checkCancellation()
                if !source.hasPrefix("/") && !source.hasPrefix("~") {
                    let paths = self.cacheDirectories(source, self.cacheRoot())
                    let validate = self.cacheIsValid
                    let valid = await Task.detached(priority: .utility) {
                        let existing = paths.filter { FileManager.default.fileExists(atPath: $0.path) }
                        return paths.isEmpty || (!existing.isEmpty && existing.allSatisfy(validate))
                    }.value
                    guard valid else { throw CacheRepairError.invalidAfterDownload }
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
                self.phase = .switching(to: model, downloading: false, progress: 0.8)
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
                self.finish(model, id: id, otherwise: .loadFailed(model))
            } catch Qwen3TranscriptionEngine.SwitchError.notLoaded {
                guard id == self.switchID else { return }
                if let observed = self.readEngineModelID() {
                    self.reconcile(model, observedModelID: observed, otherwise: .loadFailed(model))
                } else {
                    // An unload completed; save the choice for the next load.
                    self.commit(model)
                    self.phase = .idle
                }
            } catch is CancellationError {
                self.finish(model, id: id, otherwise: .idle)
            } catch Qwen3TranscriptionEngine.SwitchError.busy {
                self.finish(model, id: id, otherwise: .loadFailed(model))
            } catch {
                log.error("Model switch failed: \(error.localizedDescription, privacy: .public)")
                self.finish(model, id: id,
                            otherwise: self.downloadCompleted ? .loadFailed(model) : .failed(model))
            }
        }
        return true
    }

    func cancel() {
        guard isSwitching else { return }
        let target = shownSelection
        task?.cancel()
        let observed = gateClosed ? fenceAndReadEngine() : readEngineModelID()
        switchID += 1
        previousTask = task
        task = nil
        reconcile(target, observedModelID: observed, otherwise: .idle)
        gateClosed = false
        waitingForIdle = false
    }

    @Published private(set) var waitingForIdle = false

    private func cancelForTimeout(_ model: AppConfig.LocalModel, id: Int) {
        guard id == switchID else { return }
        task?.cancel()
        let observed = fenceAndReadEngine()
        switchID += 1
        previousTask = task
        task = nil
        reconcile(model, observedModelID: observed, otherwise: .loadFailed(model))
        gateClosed = false
        waitingForIdle = false
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
        case .loadFailed, .notLoaded:
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

    /// The saved model failed to load and nothing loaded instead. Settings
    /// shows the failure with Try Again, which reloads the saved model.
    func noteLoadFailedWithNothingLoaded(_ model: AppConfig.LocalModel) {
        guard !isSwitching else { return }
        active = model
        phase = .notLoaded(model)
    }

    /// A launch or reload load succeeded: clear a nothing-loaded failure.
    func noteModelLoaded() {
        if case .notLoaded = phase { phase = .idle }
    }

    #if DEBUG
    /// Test hook for rendering each state.
    func setPhaseForTesting(_ phase: Phase) { self.phase = phase }
    func awaitPreviousTaskForTesting() async { await previousTask?.value }
    #endif

    private func updateProgress(_ progress: Double, id: Int) {
        guard id == switchID, case .switching(let target, let downloading, _) = phase else { return }
        phase = .switching(to: target, downloading: downloading, progress: progress)
    }

    private func finish(_ model: AppConfig.LocalModel, id: Int, otherwise: Phase) {
        guard id == switchID else { return }
        reconcile(model, observedModelID: readEngineModelID(), otherwise: otherwise)
    }

    private func readEngineModelID() -> String? {
        guard let engine else { return nil }
        if let loadedModelID { return loadedModelID(engine) }
        return engine.loadedModelID
    }

    private func fenceAndReadEngine() -> String? {
        guard let engine else { return nil }
        if let fenceEngineSwitch { return fenceEngineSwitch(engine) }
        return engine.fencePendingSwitchAndGetModelID()
    }

    private func reconcile(_ target: AppConfig.LocalModel, observedModelID: String?, otherwise: Phase) {
        if observedModelID == config.modelSource(for: target) {
            let changed = active != target
            commit(target)
            phase = .idle
            if changed { MLX.Memory.clearCache() }
            return
        }
        if let observedModelID,
           let actual = AppConfig.LocalModel.allCases.first(where: { config.modelSource(for: $0) == observedModelID }),
           actual != active {
            commit(actual)
        }
        phase = otherwise
    }

    private func commit(_ model: AppConfig.LocalModel) {
        config.localModel = model
        active = model
    }

    private enum CacheRepairError: Error { case invalidAfterDownload, unsafeCachePath }

    nonisolated private static func configuredCacheRoot() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["QWEN3_CACHE_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let override = environment["QWEN3_ASR_CACHE_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }

    nonisolated static func remoteCacheDirectories(for source: String, root: URL) -> [URL] {
        let parts = source.split(separator: "/").map(String.init)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return [] }
        let base = root.appendingPathComponent("qwen3-speech", isDirectory: true)
        return [
            base.appendingPathComponent(Qwen3ASRModel.sanitizedCacheKey(for: source), isDirectory: true),
            base.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(parts[0], isDirectory: true)
                .appendingPathComponent(parts[1], isDirectory: true)
        ]
    }

    nonisolated private static func isSafeTargetCache(_ path: URL, source: String, root: URL) -> Bool {
        let expected = remoteCacheDirectories(for: source, root: root)
        guard expected.contains(where: { $0.standardizedFileURL.path == path.standardizedFileURL.path }) else {
            return false
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalExpected = remoteCacheDirectories(for: source, root: canonicalRoot)
        guard canonicalExpected.contains(where: { $0.standardizedFileURL.path ==
            path.resolvingSymlinksInPath().standardizedFileURL.path }) else { return false }

        let relativePath = String(path.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        var cursor = canonicalRoot
        for component in relativePath.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: true)
            guard let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return false }
        }
        return true
    }

    nonisolated private static func validCachedWeights(in directory: URL) -> Bool {
        let fm = FileManager.default
        let config = directory.appendingPathComponent("config.json")
        guard let configSize = try? config.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              configSize > 0,
              let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
        let weights = files.filter { $0.pathExtension == "safetensors" }
        guard !weights.isEmpty else { return false }
        for weight in weights {
            // Both picker models have hundreds of MB of weights. A file this
            // small is necessarily incomplete for either supported model.
            guard let size = try? weight.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size >= 10_000_000 else { return false }
            let metadata = directory.appendingPathComponent(".cache/huggingface/download")
                .appendingPathComponent(weight.lastPathComponent + ".metadata")
            // Missing metadata cannot prove corruption. Keep a plausible
            // offline cache rather than deleting valid weights on suspicion.
            guard let content = try? String(contentsOf: metadata, encoding: .utf8) else { continue }
            let lines = content.split(whereSeparator: \.isNewline)
            guard lines.count >= 2 else { continue }
            let etag = String(lines[1]).lowercased()
            let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")
            if etag.count == 64 && etag.unicodeScalars.allSatisfy(hexDigits.contains) {
                guard let handle = try? FileHandle(forReadingFrom: weight) else { return false }
                defer { try? handle.close() }
                var sha = SHA256()
                do {
                    while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                        sha.update(data: chunk)
                    }
                } catch { return false }
                let digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == etag else { return false }
            }
        }
        return true
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
        // A cache whose Hub download was interrupted may be missing files; it
        // is not "on disk" until the download finishes (speech-swift marker).
        return candidates.contains {
            HuggingFaceDownloader.weightsExist(in: $0)
                && !HuggingFaceDownloader.hasIncompleteDownloadMarker(in: $0)
        }
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
