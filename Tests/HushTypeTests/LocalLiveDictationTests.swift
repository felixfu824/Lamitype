import AVFoundation
import AudioCommon
import MLX
import XCTest
@testable import HushType

private final class LiveTestDriver: CaptureDriver {
    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    var feed: ((AVAudioPCMBuffer) -> Void)?
    var fail: (() -> Void)?
    var stopped = 0
    var onStop: (() -> Void)?
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onConfigurationChange: @escaping () -> Void) throws {
        feed = onBuffer; fail = onConfigurationChange
    }
    func stop() { stopped += 1; onStop?() }
    func emit(_ count: Int, value: Float = 0.1) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count { buffer.floatChannelData![0][index] = value }
        feed?(buffer)
    }
}

final class LocalLiveDictationTests: XCTestCase {
    @MainActor
    func testCapClosesProducerAtExactly960000AndLateFailureCannotEraseAudio() throws {
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        try capture.startRecording(limitSeconds: 60)
        driver.emit(959_000); driver.emit(4096); driver.emit(4096)
        XCTAssertTrue(capture.recordingLimitReached)
        XCTAssertEqual(capture.recordingSnapshot().count, 960_000)
        driver.fail?()
        XCTAssertEqual(try capture.stopRecording().count, 960_000)
        XCTAssertEqual(driver.stopped, 1)
    }

    @MainActor
    func testBatchRecordingIsNotCapped() throws {
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        try capture.startRecording()
        driver.emit(960_500)
        XCTAssertFalse(capture.recordingLimitReached)
        XCTAssertEqual(try capture.stopRecording().count, 960_500)
    }

    @MainActor
    func testTapDoesNotRecognizeOrPublishDraft() throws {
        var clock: Double = 0, calls = 0, taps = 0, loads = 0
        let tokenizer = LiveSessionTokenizer(loader: { loads += 1; return Qwen3Tokenizer() })
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { false }) { _ in
            _ = try tokenizer.load()
            calls += 1; return LiveRecognition(text: "wrong", generatedTokens: 2, endedByEOS: true)
        }
        session.onTap = { taps += 1 }
        XCTAssertTrue(try session.start(automaticTicks: false))
        clock = 0.2; driver.emit(3200); session.release()
        XCTAssertEqual(taps, 1); XCTAssertEqual(calls, 0); XCTAssertEqual(loads, 0)
        XCTAssertNil(LocalLiveOwnership.liveOwner)
    }

    @MainActor
    func testLatchedFailureBeforeShortReleaseNeverTriggersSelectionAndPresentsOnce() throws {
        var clock: Double = 0, errors = 0, taps = 0
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { false }) { _ in
            XCTFail("Failed tap must never infer"); throw LiveRecognitionError.unavailable
        }
        session.onTap = { taps += 1 }; session.onCaptureError = { _ in errors += 1 }
        XCTAssertTrue(try session.start(automaticTicks: false))
        clock = 0.1; driver.fail?(); session.release()
        XCTAssertEqual(taps, 0); XCTAssertEqual(errors, 1)
        XCTAssertEqual(session.phase, .finished)
    }

    @MainActor
    func testSlowStopCannotTurnPhysicalTapIntoHold() throws {
        var clock: Double = 0, taps = 0
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { false }) { _ in
            XCTFail("Tap must never infer"); throw LiveRecognitionError.unavailable
        }
        session.onTap = { taps += 1 }
        XCTAssertTrue(try session.start(automaticTicks: false)); driver.emit(1600)
        clock = 0.1; driver.onStop = { clock = 2 }; session.release()
        XCTAssertEqual(taps, 1)
    }

    @MainActor
    func testSecureInputDuringPreviewSuppressesPublicationBeforeNextTimerTick() async throws {
        var clock: Double = 0, secure = false
        let started = expectation(description: "preview started"), finished = expectation(description: "secure drain")
        let gate = DispatchSemaphore(value: 0)
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { secure }) { _ in
            started.fulfill(); gate.wait()
            return LiveRecognition(text: "private", generatedTokens: 2, endedByEOS: true)
        }
        session.onFinished = { finished.fulfill() }
        XCTAssertTrue(try session.start(automaticTicks: false)); driver.emit(32000)
        clock = 2; session.tick()
        await fulfillment(of: [started], timeout: 3)
        secure = true; gate.signal()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(session.draft, ""); XCTAssertTrue(session.audio.isEmpty)
        XCTAssertNil(LocalLiveOwnership.liveOwner)
    }

    @MainActor
    func testOneWholeFinalEvenAfterRepeatedReleaseAndCapTick() async throws {
        var clock: Double = 0, calls: [Int] = []
        let finished = expectation(description: "one final")
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { false }) { samples in
            calls.append(samples.count)
            return LiveRecognition(text: "final", generatedTokens: 1024, endedByEOS: true)
        }
        session.prepareFinal = { $0 }
        var results = 0
        session.onResult = { text, _ in XCTAssertEqual(text, "final"); results += 1 }
        session.onFinished = { finished.fulfill() }
        XCTAssertTrue(try session.start(automaticTicks: false))
        driver.emit(960_000); clock = 60; session.tick(); session.release(); session.tick()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(calls, [960_000]); XCTAssertEqual(results, 1)
        XCTAssertTrue(session.stoppedAtLimit)
        XCTAssertTrue(session.audio.isEmpty)
    }

    @MainActor
    func testCancelDuringInferenceKeepsLeaseUntilDrainAndNeverPublishes() async throws {
        var clock: Double = 0
        let started = expectation(description: "inference started"), finished = expectation(description: "drained")
        let gate = DispatchSemaphore(value: 0)
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { false }) { _ in
            started.fulfill(); gate.wait()
            return LiveRecognition(text: "late", generatedTokens: 2, endedByEOS: true)
        }
        session.prepareFinal = { _ in XCTFail("Cancelled result reached processor"); return nil }
        session.onResult = { _, _ in XCTFail("Late insertion") }
        session.onFinished = { finished.fulfill() }
        XCTAssertTrue(try session.start(automaticTicks: false)); driver.emit(32000)
        clock = 2; session.tick()
        await fulfillment(of: [started], timeout: 3)
        session.cancel()
        XCTAssertEqual(session.phase, .draining)
        XCTAssertEqual(LocalLiveOwnership.liveOwner, session.id)
        XCTAssertFalse(LocalLiveOwnership.beginCaptionTransition())
        gate.signal()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertNil(LocalLiveOwnership.liveOwner)
    }

    @MainActor
    func testNoEOSRetainsAudioRetryIsCopyOnlyAndDropsAudioOnSuccess() async throws {
        var clock: Double = 0, calls = 0
        let failed = expectation(description: "failure"), finished = expectation(description: "retry done")
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { false }) { _ in
            calls += 1
            return LiveRecognition(text: "answer", generatedTokens: calls == 1 ? 1024 : 10, endedByEOS: calls != 1)
        }
        session.prepareFinal = { $0 }
        session.onFailure = { _ in failed.fulfill() }
        session.onResult = { _, retried in XCTAssertTrue(retried) }
        session.onFinished = { finished.fulfill() }
        XCTAssertTrue(try session.start(automaticTicks: false)); driver.emit(16000)
        clock = 1; session.release()
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(session.phase, .recovery); XCTAssertEqual(session.audio.count, 16000)
        XCTAssertNil(LocalLiveOwnership.liveOwner)
        XCTAssertTrue(session.retry()); XCTAssertFalse(session.retry())
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(calls, 2); XCTAssertTrue(session.audio.isEmpty)
    }

    @MainActor
    func testPrivacyRevocationDiscardsPendingRecovery() async throws {
        var clock: Double = 0, secure = false
        let failed = expectation(description: "failure")
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { secure }) { _ in
            throw LiveRecognitionError.incomplete
        }
        session.onFailure = { _ in failed.fulfill() }
        XCTAssertTrue(try session.start(automaticTicks: false)); driver.emit(16000)
        clock = 1; session.release()
        await fulfillment(of: [failed], timeout: 3)
        secure = true; session.tick()
        XCTAssertEqual(session.phase, .finished); XCTAssertTrue(session.audio.isEmpty)
        XCTAssertFalse(session.retry())
    }

    @MainActor
    func testLeaseRestoresPriorCacheAndRejectsPendingOrActiveLocalCaption() {
        let prior = MLX.Memory.cacheLimit
        let owner = UUID()
        LocalLiveOwnership.captionTransitions += 1
        XCTAssertFalse(LocalLiveOwnership.acquire(owner))
        LocalLiveOwnership.endCaptionTransition()
        LocalLiveOwnership.localCaptionActive = true
        XCTAssertFalse(LocalLiveOwnership.acquire(owner))
        LocalLiveOwnership.localCaptionActive = false
        XCTAssertTrue(LocalLiveOwnership.acquire(owner))
        XCTAssertEqual(MLX.Memory.cacheLimit, 128 * 1024 * 1024)
        LocalLiveOwnership.release(UUID())
        XCTAssertEqual(LocalLiveOwnership.liveOwner, owner)
        LocalLiveOwnership.release(owner)
        XCTAssertEqual(MLX.Memory.cacheLimit, prior)
    }
    func testSessionTokenizerLoadsOnceForMultipleInferenceCalls() async throws {
        var loads = 0
        let holder = LiveSessionTokenizer(loader: { loads += 1; return Qwen3Tokenizer() })
        XCTAssertEqual(loads, 0)
        let first = try await LocalLiveInference.run { try holder.load() }
        for _ in 0..<4 {
            let again = try await LocalLiveInference.run { try holder.load() }
            XCTAssertTrue(first === again)
        }
        XCTAssertEqual(loads, 1)
    }
    func testSessionTokenizerRetriesFailedLoadWithoutCachingFailure() async throws {
        var loads = 0
        let holder = LiveSessionTokenizer(loader: {
            loads += 1
            if loads == 1 { throw LiveRecognitionError.unavailable }
            return Qwen3Tokenizer()
        })
        do { _ = try await LocalLiveInference.run { try holder.load() }; XCTFail("Expected failed load") }
        catch { XCTAssertEqual(loads, 1) }
        _ = try await LocalLiveInference.run { try holder.load() }
        _ = try await LocalLiveInference.run { try holder.load() }
        XCTAssertEqual(loads, 2)
    }
    @MainActor func testTokenizerLoadFailureRetainsRecordingWithoutInsertion() async throws {
        var clock: Double = 0, insertions = 0
        let failed = expectation(description: "loader failure recovery")
        let holder = LiveSessionTokenizer(loader: { throw LiveRecognitionError.unavailable })
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { false }) { _ in
            _ = try holder.load(); return LiveRecognition(text: "unexpected", generatedTokens: 2, endedByEOS: true)
        }
        session.onFailure = { _ in failed.fulfill() }; session.onResult = { _,_ in insertions += 1 }
        XCTAssertTrue(try session.start(automaticTicks: false)); driver.emit(16000)
        clock = 1; session.release(); await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(session.phase, .recovery); XCTAssertEqual(session.audio.count, 16000)
        XCTAssertEqual(insertions, 0); XCTAssertNil(LocalLiveOwnership.liveOwner)
        session.cancel()
    }
    @MainActor func testCancelDuringTokenizerLoadDrainsBeforeReleasingOwnership() async throws {
        var clock: Double = 0, results = 0
        let began = expectation(description: "loader active"), finished = expectation(description: "cancel drained")
        let gate = DispatchSemaphore(value: 0)
        let holder = LiveSessionTokenizer(loader: { began.fulfill(); gate.wait(); return Qwen3Tokenizer() })
        let driver = LiveTestDriver(), capture = AudioCaptureService(makeDriver: { driver })
        let session = LocalLiveDictationSession(capture: capture, now: { clock }, isSecure: { false }) { _ in
            _ = try holder.load(); return LiveRecognition(text: "late", generatedTokens: 2, endedByEOS: true)
        }
        session.onResult = { _,_ in results += 1 }; session.onFinished = { finished.fulfill() }
        XCTAssertTrue(try session.start(automaticTicks: false)); driver.emit(32000); clock = 2; session.tick()
        await fulfillment(of: [began], timeout: 3); session.cancel()
        XCTAssertEqual(session.phase, .draining); XCTAssertNotNil(LocalLiveOwnership.liveOwner)
        gate.signal(); await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(session.draft, ""); XCTAssertEqual(results, 0); XCTAssertTrue(session.audio.isEmpty)
        XCTAssertNil(LocalLiveOwnership.liveOwner)
    }

}
