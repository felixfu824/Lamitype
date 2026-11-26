import AppKit
import XCTest
@testable import HushType

@MainActor
final class LiveCaptionManagerRestartTests: XCTestCase {
    private struct State: Equatable {
        var mode: AppConfig.CaptionMode?
        var source: AudioSourceKind?

        static let off = State()
    }

    private struct Pipeline {
        var engine: AppConfig.LiveCaptionEngine
        var sourceKind: AudioSourceKind
        var backend: StubBackend
        var source: StubSource
    }

    private let config = AppConfig.shared
    private var manager: LiveCaptionManager!
    private var states: [State] = []
    private var publishedMicGateStates: [Bool] = []
    private var pipelines: [Pipeline] = []
    private var failingSource: AudioSourceKind?
    private var failingEngine: AppConfig.LiveCaptionEngine?
    private var originalEngine: AppConfig.LiveCaptionEngine = .local
    private var originalEnabled = false
    private var originalUsesMic = false
    private var originalLocalCaptionActive = false
    private var originalDefaults: [(String, Any?)] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        originalEngine = config.liveCaptionEngine
        originalEnabled = config.liveCaptionEnabled
        originalUsesMic = config.liveCaptionUsesMicSource
        originalLocalCaptionActive = LocalLiveOwnership.localCaptionActive
        let keys = [
            "hushtype.lastStartedCaptionMode",
            "hushtype.lastStartedCaptionUsesMicSource",
            LiveCaptionPanelFrameStore.frameKey,
        ] + LiveCaptionPanelFrameStore.legacyFrameKeys
        originalDefaults = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }

        manager = LiveCaptionManager(
            localEngine: Qwen3TranscriptionEngine(),
            captureService: AudioCaptureService()
        )
        manager.onStateChanged = { [weak self] mode, source in
            guard let self else { return }
            states.append(State(mode: mode, source: source))
            publishedMicGateStates.append(config.liveCaptionUsesMicSource)
        }
        manager.makeCaptionPipelineForTesting = { [unowned self] engine, source in
            let backend = StubBackend()
            let audioSource = StubSource(shouldFail: source == failingSource || engine == failingEngine)
            pipelines.append(Pipeline(engine: engine, sourceKind: source, backend: backend, source: audioSource))
            return (backend, audioSource)
        }
    }

    override func tearDown() async throws {
        manager.stop()
        await waitUntil { !manager.isStopping }
        manager = nil
        config.liveCaptionEngine = originalEngine
        config.liveCaptionEnabled = originalEnabled
        config.liveCaptionUsesMicSource = originalUsesMic
        LocalLiveOwnership.localCaptionActive = originalLocalCaptionActive
        for (key, value) in originalDefaults {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    func testFailedSourceRestartPublishesOffAndHidesPanel() async throws {
        config.liveCaptionEngine = .local
        try await manager.start(source: .mic)
        XCTAssertTrue(config.liveCaptionUsesMicSource)
        XCTAssertTrue(manager.isPanelVisible)

        let replacement = AudioSourceKind.system(bundleID: "test.caption.replacement")
        failingSource = replacement
        do {
            try await manager.switchSource(to: replacement)
            XCTFail("Expected the replacement audio source to fail")
        } catch StubSource.StartError.unavailable {
            // The manager must propagate the actual startup error.
        }

        assertOff()
        XCTAssertEqual(states, [State(mode: .local, source: .mic), .off])
        XCTAssertEqual(publishedMicGateStates, [true, true])
        XCTAssertEqual(pipelines.map(\.sourceKind), [.mic, replacement])
        let first = try XCTUnwrap(pipelines.first)
        let last = try XCTUnwrap(pipelines.last)
        XCTAssertEqual(first.backend.stopCount, 1)
        XCTAssertEqual(last.backend.stopCount, 1)
        XCTAssertEqual(first.source.stopCount, 1)
        XCTAssertEqual(last.source.stopCount, 1)
    }

    func testEngineSwitchRecreatesBackendAndPublishesReplacementMode() async throws {
        config.liveCaptionEngine = .local
        try await manager.start(source: .mic)
        await manager.switchEngine(to: .cloudTranslate)

        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(manager.isPanelVisible)
        XCTAssertTrue(config.liveCaptionEnabled)
        XCTAssertTrue(config.liveCaptionUsesMicSource)
        XCTAssertFalse(LocalLiveOwnership.localCaptionActive)
        XCTAssertEqual(manager.currentSource, .mic)
        XCTAssertEqual(states, [
            State(mode: .local, source: .mic),
            .off,
            State(mode: .translated, source: .mic),
        ])
        XCTAssertEqual(publishedMicGateStates, [true, true, true])
        try assertBackendReplaced(from: .local, to: .cloudTranslate, source: .mic)

        manager.stop()
        XCTAssertFalse(config.liveCaptionUsesMicSource)
        XCTAssertEqual(publishedMicGateStates, [true, true, true, false])
    }

    func testSourceSwitchReservesMicUntilReplacementIsActive() async throws {
        config.liveCaptionEngine = .local
        let system = AudioSourceKind.system(bundleID: "test.caption.system")
        try await manager.start(source: system)
        try await manager.switchSource(to: .mic)
        XCTAssertTrue(config.liveCaptionUsesMicSource)
        try await manager.switchSource(to: system)
        XCTAssertFalse(config.liveCaptionUsesMicSource)
        XCTAssertEqual(states, [
            State(mode: .local, source: system), .off,
            State(mode: .local, source: .mic), .off,
            State(mode: .local, source: system),
        ])
        XCTAssertEqual(publishedMicGateStates, [false, true, true, true, false])
    }

    func testSwitchToLocalAfterCloudConnectionLossRestartsCaptions() async throws {
        let source = AudioSourceKind.system(bundleID: "test.caption.system")
        try await startCloudAndChooseLocalAfterConnectionLoss(source: source)
        await waitUntil { states.last?.mode == .local }

        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(manager.isPanelVisible)
        XCTAssertTrue(config.liveCaptionEnabled)
        XCTAssertFalse(config.liveCaptionUsesMicSource)
        XCTAssertTrue(LocalLiveOwnership.localCaptionActive)
        XCTAssertEqual(manager.currentSource, source)
        XCTAssertEqual(states, [State(mode: .translated, source: source), .off, State(mode: .local, source: source)])
        XCTAssertEqual(publishedMicGateStates, [false, false, false])
        try assertBackendReplaced(from: .cloudTranslate, to: .local, source: source)
    }

    func testSwitchToLocalAfterCloudConnectionLossLeavesCaptionsOffIfRestartFails() async throws {
        failingEngine = .local
        try await startCloudAndChooseLocalAfterConnectionLoss(source: .mic)
        await waitUntil { !manager.isPanelVisible }

        assertOff()
        XCTAssertEqual(states, [State(mode: .translated, source: .mic), .off])
        XCTAssertEqual(publishedMicGateStates, [true, true])
        XCTAssertEqual(config.liveCaptionEngine, .local)
        XCTAssertEqual(pipelines.map(\.engine), [.cloudTranslate, .local])
        let failed = try XCTUnwrap(pipelines.last)
        XCTAssertEqual(failed.backend.startCount, 1)
        XCTAssertEqual(failed.backend.stopCount, 1)
        XCTAssertEqual(failed.source.stopCount, 1)
    }

    private func startCloudAndChooseLocalAfterConnectionLoss(source: AudioSourceKind) async throws {
        config.liveCaptionEngine = .cloudTranslate
        manager.cloudErrorResponseForTesting = .alertFirstButtonReturn
        try await manager.start(source: source)
        let cloud = try XCTUnwrap(pipelines.first?.backend)
        cloud.emit(.error(URLError(.networkConnectionLost)))
    }

    private func assertBackendReplaced(
        from previous: AppConfig.LiveCaptionEngine,
        to replacement: AppConfig.LiveCaptionEngine,
        source: AudioSourceKind
    ) throws {
        XCTAssertEqual(pipelines.map(\.engine), [previous, replacement])
        XCTAssertEqual(pipelines.map(\.sourceKind), [source, source])
        let first = try XCTUnwrap(pipelines.first)
        let last = try XCTUnwrap(pipelines.last)
        XCTAssertFalse(first.backend === last.backend)
        XCTAssertEqual(first.backend.stopCount, 1)
        XCTAssertEqual(last.backend.startCount, 1)
        XCTAssertEqual(last.backend.stopCount, 0)
        XCTAssertEqual(first.source.stopCount, 1)
        XCTAssertEqual(last.source.stopCount, 0)
    }

    private func assertOff(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(manager.isActive, file: file, line: line)
        XCTAssertNil(manager.currentSource, file: file, line: line)
        XCTAssertFalse(manager.isPanelVisible, file: file, line: line)
        XCTAssertFalse(config.liveCaptionEnabled, file: file, line: line)
        XCTAssertFalse(config.liveCaptionUsesMicSource, file: file, line: line)
        XCTAssertFalse(LocalLiveOwnership.localCaptionActive, file: file, line: line)
    }

    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for caption state", file: file, line: line)
    }
}

@MainActor
private final class StubBackend: TranscriptionBackend {
    nonisolated let events: AsyncStream<BackendEvent>
    private let continuation: AsyncStream<BackendEvent>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func start() async throws { startCount += 1 }
    func feed(samples: [Float]) async {}
    func stop() async {
        stopCount += 1
        continuation.finish()
    }

    func emit(_ event: BackendEvent) {
        continuation.yield(event)
    }
}

// The manager configures callbacks and starts/stops these stubs on the main actor.
private final class StubSource: AudioSource, @unchecked Sendable {
    enum StartError: Error { case unavailable }

    var onSamples: (([Float]) -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var stopCount = 0
    private let shouldFail: Bool

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func start() async throws {
        if shouldFail { throw StartError.unavailable }
    }

    func stop() { stopCount += 1 }
}
