import XCTest
@testable import HushType

@MainActor
final class LocalModelSwitchTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var config: AppConfig!

    override func setUp() async throws {
        suiteName = "LocalModelSwitchTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        config = AppConfig.forUpgradeTesting(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsToFast() {
        XCTAssertEqual(config.localModel, .fast)
        XCTAssertEqual(config.modelId, "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
    }

    func testModelIdFollowsChoiceAndLocalFolderOverride() {
        config.localModel = .optimized
        XCTAssertEqual(config.modelId, "felixfu824/Qwen3-ASR-0.6B-MLX-mixed-6-8bit")
        defaults.set("/tmp/optimized-model", forKey: "hushtype.optimizedModelPath")
        XCTAssertEqual(config.modelId, "/tmp/optimized-model")
        XCTAssertEqual(config.modelSource(for: .fast), "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
    }

    func testExplicitModelIdStillWins() {
        config.localModel = .optimized
        config.modelId = "custom/model"
        XCTAssertEqual(config.modelId, "custom/model")
    }

    func testUnknownStoredChoiceFallsBackToFast() {
        defaults.set("turbo", forKey: "hushtype.localModel")
        XCTAssertEqual(config.localModel, .fast)
    }

    func testWeightsOnDiskForLocalFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lamitype-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(LocalModelSwitcher.weightsOnDisk(source: folder.path))
        try Data([0]).write(to: folder.appendingPathComponent("model.safetensors"))
        XCTAssertTrue(LocalModelSwitcher.weightsOnDisk(source: folder.path))
        XCTAssertFalse(LocalModelSwitcher.weightsOnDisk(source: folder.appendingPathComponent("missing").path))
    }

    func testSelectWithoutLoadedModelSavesChoiceForNextLoad() {
        let switcher = LocalModelSwitcher(config: config)
        switcher.engine = Qwen3TranscriptionEngine()
        XCTAssertTrue(switcher.select(.optimized))
        XCTAssertEqual(switcher.active, .optimized)
        XCTAssertEqual(config.localModel, .optimized)
        XCTAssertEqual(switcher.phase, .idle)
    }

    func testSelectRefusedWhileBusy() {
        let switcher = LocalModelSwitcher(config: config)
        switcher.engine = Qwen3TranscriptionEngine()
        switcher.isBusy = { true }
        XCTAssertFalse(switcher.select(.optimized))
        XCTAssertEqual(switcher.active, .fast)
        XCTAssertEqual(config.localModel, .fast)
    }

    func testSelectRefusedWhileCaptionTransitionOrModelLoadRuns() {
        let switcher = LocalModelSwitcher(config: config)
        switcher.engine = Qwen3TranscriptionEngine()
        switcher.isBusy = { LocalLiveOwnership.captionTransitions > 0 }
        XCTAssertTrue(LocalLiveOwnership.beginCaptionTransition())
        XCTAssertFalse(switcher.select(.optimized))
        LocalLiveOwnership.endCaptionTransition()
        switcher.loadInFlight = { _ in true }
        XCTAssertFalse(switcher.select(.optimized))
        XCTAssertEqual(config.localModel, .fast)
    }

    func testSelectingActiveModelIsNoOp() {
        let switcher = LocalModelSwitcher(config: config)
        switcher.isBusy = { true }
        XCTAssertTrue(switcher.select(.fast))
        XCTAssertEqual(switcher.phase, .idle)
        XCTAssertNil(switcher.statusText)
    }

    func testFallbackSourceOnlyForOptimizedWithoutOverride() {
        XCTAssertNil(config.fallbackModelSource)
        config.localModel = .optimized
        XCTAssertEqual(config.fallbackModelSource, "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
        config.modelId = "custom/model"
        XCTAssertNil(config.fallbackModelSource)
    }

    func testLoadFallbackShowsFailureAndKeepsSavedChoice() {
        config.localModel = .optimized
        let switcher = LocalModelSwitcher(config: config)
        XCTAssertEqual(switcher.active, .optimized)
        switcher.noteLoadFallback(failed: .optimized, using: .fast)
        XCTAssertEqual(switcher.active, .fast)
        XCTAssertEqual(switcher.shownSelection, .fast)
        XCTAssertEqual(switcher.phase, .loadFailed(.optimized))
        XCTAssertNotNil(switcher.statusText)
        XCTAssertEqual(config.localModel, .optimized, "The next launch tries the saved model again")
    }

    func testChoosingModelInUseAfterFallbackSavesIt() {
        config.localModel = .optimized
        let switcher = LocalModelSwitcher(config: config)
        switcher.noteLoadFallback(failed: .optimized, using: .fast)
        XCTAssertTrue(switcher.select(.fast))
        XCTAssertEqual(switcher.phase, .idle)
        XCTAssertEqual(config.localModel, .fast)
    }

    func testEngineSwitchRequiresLoadedModel() async {
        let engine = Qwen3TranscriptionEngine()
        do {
            try await engine.switchModel(to: "unused/model")
            XCTFail("Expected notLoaded")
        } catch {
            XCTAssertEqual(error as? Qwen3TranscriptionEngine.SwitchError, .notLoaded)
        }
        XCTAssertNil(engine.loadedModelID)
    }

    func testDisplayNamesHaveNoLanguageClaims() {
        for model in AppConfig.LocalModel.allCases {
            for text in [model.displayName, model.shortName] {
                for word in ["Mandarin", "Taiwan", "accent", "English", "Chinese", "%"] {
                    XCTAssertFalse(text.contains(word), "\(text) mentions \(word)")
                }
            }
        }
    }

    private func fakeSwitcher() -> LocalModelSwitcher {
        let switcher = LocalModelSwitcher(config: config)
        switcher.engine = Qwen3TranscriptionEngine()
        switcher.hasLoadedModel = { _ in true }
        let fastID = config.modelSource(for: .fast)
        switcher.loadedModelID = { _ in fastID }
        switcher.fenceEngineSwitch = { _ in fastID }
        switcher.download = { _, _ in }
        switcher.cacheDirectories = { _, _ in [] }
        return switcher
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for switch state")
    }

    func testSwapWaitsForSessionThenClosesGate() async throws {
        let switcher = fakeSwitcher()
        var busy = false
        var installedID = config.modelSource(for: .fast)
        switcher.loadedModelID = { _ in installedID }
        switcher.isBusy = { busy }
        switcher.loadAndSwap = { _, target in
            try await Task.sleep(nanoseconds: 100_000_000)
            installedID = target
        }
        XCTAssertTrue(switcher.select(.optimized))
        busy = true
        try await waitFor { switcher.waitingForIdle }
        XCTAssertEqual(switcher.active, .fast)
        XCTAssertFalse(switcher.refusesLocalRequests)
        busy = false
        try await waitFor { switcher.refusesLocalRequests }
        XCTAssertTrue(switcher.refusesLocalRequests)
        try await waitFor { switcher.phase == .idle }
        XCTAssertFalse(switcher.refusesLocalRequests)
        XCTAssertEqual(config.localModel, .optimized)
    }

    func testCaptionStopRemainsBusyUntilTeardownFinishes() async throws {
        let manager = LiveCaptionManager(localEngine: Qwen3TranscriptionEngine(),
                                         captureService: AudioCaptureService())
        var releaseStop: CheckedContinuation<Void, Never>?
        manager.stopTeardownBarrierForTesting = {
            await withCheckedContinuation { releaseStop = $0 }
        }
        let switcher = fakeSwitcher()
        var installedID = config.modelSource(for: .fast)
        switcher.loadedModelID = { _ in installedID }
        switcher.isBusy = {
            manager.isActive || manager.isStopping || LocalLiveOwnership.captionTransitions > 0
        }
        switcher.loadAndSwap = { _, target in
            installedID = target
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(switcher.select(.optimized))
        manager.activateForTesting()
        try await waitFor { switcher.waitingForIdle }
        manager.stop()
        XCTAssertFalse(manager.isActive)
        XCTAssertTrue(manager.isStopping)
        try await waitFor { releaseStop != nil }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(switcher.waitingForIdle)
        XCTAssertFalse(switcher.gateClosed)
        releaseStop?.resume()
        try await waitFor { !manager.isStopping }
        try await waitFor { switcher.phase == .idle }
        XCTAssertEqual(config.localModel, .optimized)
    }

    func testCancelDuringDownloadKeepsChoice() async throws {
        let switcher = fakeSwitcher()
        var enteredDownload = false
        switcher.download = { _, _ in
            enteredDownload = true
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { enteredDownload }
        switcher.cancel()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(switcher.active, .fast)
        XCTAssertEqual(config.localModel, .fast)
        XCTAssertFalse(switcher.refusesLocalRequests)
    }

    func testCorruptRemoteCacheIsRemovedBeforeDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamitype-cache-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LocalModelSwitcher.remoteCacheDirectories(
            for: config.modelSource(for: .optimized), root: root)
        let flat = paths[0]
        let hub = paths[1]
        let flatWeight = flat.appendingPathComponent("model.safetensors")
        let hubWeight = hub.appendingPathComponent("model.safetensors")
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: flatWeight)
        try Data("corrupt".utf8).write(to: hubWeight)

        let switcher = fakeSwitcher()
        var installedID = config.modelSource(for: .fast)
        var downloads = 0
        switcher.loadedModelID = { _ in installedID }
        switcher.cacheRoot = { root }
        switcher.cacheDirectories = { source, root in
            LocalModelSwitcher.remoteCacheDirectories(for: source, root: root)
        }
        switcher.cacheIsValid = { directory in
            (try? Data(contentsOf: directory.appendingPathComponent("model.safetensors"))) == Data("complete".utf8)
        }
        switcher.download = { _, _ in
            downloads += 1
            // Reproduce Hub's metadata fast path: an existing destination is
            // treated as current even if the payload is corrupt.
            if FileManager.default.fileExists(atPath: hubWeight.path) { return }
            try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
            try Data("complete".utf8).write(to: hubWeight)
        }
        switcher.loadAndSwap = { _, target in
            guard (try? Data(contentsOf: hubWeight)) == Data("complete".utf8) else {
                throw NSError(domain: "corrupt-cache", code: 1)
            }
            installedID = target
        }

        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { switcher.phase == .idle && switcher.active == .optimized }
        XCTAssertEqual(downloads, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flatWeight.path))
        XCTAssertEqual(try Data(contentsOf: hubWeight), Data("complete".utf8))
        XCTAssertEqual(config.localModel, .optimized)
    }

    func testInvalidFlatCacheDoesNotDeleteValidHubCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamitype-cache-layouts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LocalModelSwitcher.remoteCacheDirectories(
            for: config.modelSource(for: .optimized), root: root)
        let flatWeight = paths[0].appendingPathComponent("model.safetensors")
        let hubWeight = paths[1].appendingPathComponent("model.safetensors")
        try FileManager.default.createDirectory(at: paths[0], withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths[1], withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: flatWeight)
        try Data("complete".utf8).write(to: hubWeight)

        let switcher = fakeSwitcher()
        var installedID = config.modelSource(for: .fast)
        switcher.loadedModelID = { _ in installedID }
        switcher.cacheRoot = { root }
        switcher.cacheDirectories = { source, root in
            LocalModelSwitcher.remoteCacheDirectories(for: source, root: root)
        }
        switcher.cacheIsValid = { directory in
            (try? Data(contentsOf: directory.appendingPathComponent("model.safetensors"))) == Data("complete".utf8)
        }
        switcher.download = { _, _ in
            guard FileManager.default.fileExists(atPath: hubWeight.path) else {
                throw NSError(domain: "valid-hub-cache-deleted", code: 1)
            }
        }
        switcher.loadAndSwap = { _, target in installedID = target }

        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { switcher.phase == .idle && switcher.active == .optimized }
        XCTAssertFalse(FileManager.default.fileExists(atPath: flatWeight.path))
        XCTAssertEqual(try Data(contentsOf: hubWeight), Data("complete".utf8))
    }

    func testSymlinkedCacheParentIsNeverDeleted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamitype-cache-symlink-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamitype-cache-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = config.modelSource(for: .optimized)
        let components = source.split(separator: "/").map(String.init)
        let escaped = outside.appendingPathComponent(components[0], isDirectory: true)
            .appendingPathComponent(components[1], isDirectory: true)
        let weight = escaped.appendingPathComponent("model.safetensors")
        try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: weight)
        let base = root.appendingPathComponent("qwen3-speech", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("models"), withDestinationURL: outside)

        let switcher = fakeSwitcher()
        switcher.cacheRoot = { root }
        switcher.cacheDirectories = { source, root in
            LocalModelSwitcher.remoteCacheDirectories(for: source, root: root)
        }
        switcher.cacheIsValid = { _ in false }
        switcher.download = { _, _ in XCTFail("Unsafe cache must be rejected before download") }

        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { switcher.phase == .failed(.optimized) }
        XCTAssertEqual(try Data(contentsOf: weight), Data("corrupt".utf8))
        XCTAssertEqual(config.localModel, .fast)
    }

    func testCancelDuringCacheValidationPreventsDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamitype-cache-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalModelSwitcher.remoteCacheDirectories(
            for: config.modelSource(for: .optimized), root: root)[1]
        let weight = hub.appendingPathComponent("model.safetensors")
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: weight)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let switcher = fakeSwitcher()
        switcher.cacheRoot = { root }
        switcher.cacheDirectories = { source, root in
            LocalModelSwitcher.remoteCacheDirectories(for: source, root: root)
        }
        switcher.cacheIsValid = { _ in
            entered.signal()
            release.wait()
            return false
        }
        switcher.download = { _, _ in XCTFail("Cancelled selection must not download") }

        XCTAssertTrue(switcher.select(.optimized))
        await Task.detached { entered.wait() }.value
        switcher.cancel()
        release.signal()
        await switcher.awaitPreviousTaskForTesting()
        XCTAssertEqual(try Data(contentsOf: weight), Data("corrupt".utf8))
        XCTAssertEqual(config.localModel, .fast)
    }

    func testTransientLoadFailureRetryKeepsValidRemoteCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamitype-load-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = LocalModelSwitcher.remoteCacheDirectories(
            for: config.modelSource(for: .optimized), root: root)[1]
        let weight = folder.appendingPathComponent("model.safetensors")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("complete".utf8).write(to: weight)

        let switcher = fakeSwitcher()
        var installedID = config.modelSource(for: .fast)
        var downloads = 0
        var loads = 0
        var freshDownloads = 0
        switcher.loadedModelID = { _ in installedID }
        switcher.cacheRoot = { root }
        switcher.cacheDirectories = { source, root in
            LocalModelSwitcher.remoteCacheDirectories(for: source, root: root)
        }
        switcher.cacheIsValid = { directory in
            (try? Data(contentsOf: directory.appendingPathComponent("model.safetensors"))) == Data("complete".utf8)
        }
        switcher.download = { _, _ in
            downloads += 1
            if !FileManager.default.fileExists(atPath: weight.path) {
                freshDownloads += 1
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("complete".utf8).write(to: weight)
            }
        }
        switcher.loadAndSwap = { _, target in
            loads += 1
            if loads == 1 { throw NSError(domain: "test-load-failure", code: 1) }
            installedID = target
        }

        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { switcher.phase == .loadFailed(.optimized) }
        XCTAssertEqual(try Data(contentsOf: weight), Data("complete".utf8))
        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { switcher.phase == .idle && switcher.active == .optimized }
        XCTAssertEqual(downloads, 2)
        XCTAssertEqual(freshDownloads, 0, "A transient load failure must not erase a valid offline cache")
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(config.localModel, .optimized)
    }

    func testImmediateReselectAfterCancelWaitsForOldTask() async throws {
        let switcher = fakeSwitcher()
        let probe = BlockingSwapProbe()
        var installedID = config.modelSource(for: .fast)
        switcher.loadedModelID = { _ in installedID }
        switcher.loadAndSwap = { _, target in
            try await probe.run()
            try Task.checkCancellation()
            installedID = target
        }
        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { probe.firstStarted }
        switcher.cancel()
        XCTAssertTrue(switcher.select(.optimized))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(probe.attempts, 1, "The new switch must await the old loader")
        probe.releaseFirst()
        try await waitFor { switcher.phase == .idle }
        XCTAssertEqual(probe.attempts, 2)
        XCTAssertEqual(config.localModel, .optimized)
    }

    func testLoadFailureReopensGate() async throws {
        let switcher = fakeSwitcher()
        switcher.loadAndSwap = { _, _ in throw NSError(domain: "test", code: 1) }
        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { switcher.phase == .loadFailed(.optimized) }
        XCTAssertFalse(switcher.refusesLocalRequests)
        XCTAssertEqual(config.localModel, .fast)
    }

    func testDownloadAndLoadFailuresHaveDistinctStates() async throws {
        let switcher = fakeSwitcher()
        switcher.download = { _, _ in throw NSError(domain: "download-test", code: 1) }
        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { switcher.phase == .failed(.optimized) }
        XCTAssertFalse(switcher.refusesLocalRequests)
        XCTAssertEqual(config.localModel, .fast)
        let downloadText = switcher.statusText

        switcher.download = { _, _ in }
        switcher.loadAndSwap = { _, _ in throw NSError(domain: "load-test", code: 2) }
        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { switcher.phase == .loadFailed(.optimized) }
        XCTAssertNotEqual(switcher.statusText, downloadText)
        XCTAssertEqual(config.localModel, .fast)
    }

    func testGateTimeoutReopens() async throws {
        let switcher = fakeSwitcher()
        switcher.gateTimeoutNanoseconds = 20_000_000
        switcher.loadAndSwap = { _, _ in try await Task.sleep(nanoseconds: 5_000_000_000) }
        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { switcher.phase == .loadFailed(.optimized) }
        XCTAssertFalse(switcher.refusesLocalRequests)
        XCTAssertEqual(config.localModel, .fast)
    }

    func testCancelAfterEngineCommitReconcilesChoice() async throws {
        let switcher = fakeSwitcher()
        let probe = ControlledCommittedSwitch(fastID: config.modelSource(for: .fast),
                                              targetID: config.modelSource(for: .optimized))
        switcher.loadedModelID = { _ in probe.modelID }
        switcher.fenceEngineSwitch = { _ in probe.fenceAndRead() }
        switcher.loadAndSwap = { _, _ in await probe.commitThenHold() }
        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { probe.didCommit }
        switcher.cancel()
        XCTAssertEqual(probe.modelID, config.modelSource(for: .optimized))
        XCTAssertEqual(switcher.active, .optimized)
        XCTAssertEqual(config.localModel, .optimized)
        XCTAssertEqual(switcher.phase, .idle)
        XCTAssertFalse(switcher.gateClosed)
        probe.release()
    }

    func testWatchdogAfterEngineCommitReconcilesChoice() async throws {
        let switcher = fakeSwitcher()
        let probe = ControlledCommittedSwitch(fastID: config.modelSource(for: .fast),
                                              targetID: config.modelSource(for: .optimized))
        switcher.loadedModelID = { _ in probe.modelID }
        switcher.fenceEngineSwitch = { _ in probe.fenceAndRead() }
        switcher.loadAndSwap = { _, _ in await probe.commitThenHold() }
        switcher.gateTimeoutNanoseconds = 30_000_000
        XCTAssertTrue(switcher.select(.optimized))
        try await waitFor { probe.didCommit }
        try await waitFor { switcher.phase == .idle }
        XCTAssertEqual(probe.modelID, config.modelSource(for: .optimized))
        XCTAssertEqual(switcher.active, .optimized)
        XCTAssertEqual(config.localModel, .optimized)
        XCTAssertFalse(switcher.gateClosed)
        probe.release()
    }

}

@MainActor
private final class BlockingSwapProbe {
    private var release: CheckedContinuation<Void, Never>?
    private var running = false
    private(set) var attempts = 0
    var firstStarted: Bool { release != nil }

    func run() async throws {
        attempts += 1
        if running { throw Qwen3TranscriptionEngine.SwitchError.busy }
        running = true
        if attempts == 1 {
            await withCheckedContinuation { release = $0 }
        }
        running = false
    }

    func releaseFirst() {
        release?.resume()
        release = nil
    }
}

@MainActor
private final class ControlledCommittedSwitch {
    private let commits = SharedModelCommitState<NSObject>()
    private let fast = NSObject()
    private let optimized = NSObject()
    private let fastID: String
    private let targetID: String
    private var releaseHold: CheckedContinuation<Void, Never>?
    private(set) var didCommit = false

    init(fastID: String, targetID: String) {
        self.fastID = fastID
        self.targetID = targetID
        _ = commits.acceptLoad(fast, generation: 0)
    }

    var modelID: String? {
        if commits.model === optimized { return targetID }
        if commits.model === fast { return fastID }
        return nil
    }

    func commitThenHold() async {
        didCommit = commits.swap(optimized, generation: 0)
        await withCheckedContinuation { releaseHold = $0 }
    }

    func fenceAndRead() -> String? {
        commits.fencePendingSwitch()
        return modelID
    }

    func release() {
        releaseHold?.resume()
        releaseHold = nil
    }
}
