import AVFoundation
import XCTest
@testable import HushType

// MARK: - Fakes

/// Stand-in for `AVEngineCaptureDriver`. No `AVAudioEngine`, no microphone,
/// no permission prompt. Saved callbacks are deliberately retained after
/// `stop()` so a test can fire a late buffer or configuration change.
private final class FakeCaptureDriver: CaptureDriver {
    var format: AVAudioFormat
    var startError: Error?
    var fireConfigurationChangeDuringStart = false

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stopRanOnMainThread: [Bool] = []

    private(set) var savedOnBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var savedOnConfigurationChange: (() -> Void)?

    /// Invoked synchronously inside `stop()`, while the service still holds a
    /// live Capture. This is how a callback that was already in flight when
    /// stop began is reproduced, with no sleep and no second seam. One-shot,
    /// so a reentrant release cannot recurse.
    var duringStop: ((FakeCaptureDriver) -> Void)?

    init(format: AVAudioFormat) {
        self.format = format
    }

    var inputFormat: AVAudioFormat { format }

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onConfigurationChange: @escaping () -> Void
    ) throws {
        startCount += 1
        savedOnBuffer = onBuffer
        savedOnConfigurationChange = onConfigurationChange
        if fireConfigurationChangeDuringStart {
            onConfigurationChange()
        }
        if let startError {
            savedOnBuffer = nil
            savedOnConfigurationChange = nil
            throw startError
        }
    }

    func stop() {
        stopCount += 1
        stopRanOnMainThread.append(Thread.isMainThread)
        let hook = duringStop
        duringStop = nil
        hook?(self)
    }
}

private final class DriverFactory {
    var format: AVAudioFormat
    var nextStartError: Error?
    var fireConfigurationChangeDuringNextStart = false
    private(set) var drivers: [FakeCaptureDriver] = []

    init(format: AVAudioFormat) {
        self.format = format
    }

    func make() -> any CaptureDriver {
        let driver = FakeCaptureDriver(format: format)
        driver.startError = nextStartError
        driver.fireConfigurationChangeDuringStart = fireConfigurationChangeDuringNextStart
        nextStartError = nil
        fireConfigurationChangeDuringNextStart = false
        drivers.append(driver)
        return driver
    }

    var last: FakeCaptureDriver { drivers[drivers.count - 1] }
}

private enum FakeDriverError: Error {
    case hardwareRefused
}

private final class Consumer {}

/// Lets a callback reach the service that owns it without a capture cycle.
private final class ServiceBox {
    weak var service: AudioCaptureService?
}

// MARK: - Tests

final class AudioCaptureServiceTests: XCTestCase {
    private var factory: DriverFactory!
    private var nativeFormat: AVAudioFormat!
    private var errors: [Error] = []
    private var errorThreadWasMain: [Bool] = []

    override func setUp() {
        super.setUp()
        nativeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
        factory = DriverFactory(format: nativeFormat)
        errors = []
        errorThreadWasMain = []
    }

    override func tearDown() {
        factory = nil
        nativeFormat = nil
        super.tearDown()
    }

    private func makeService() -> AudioCaptureService {
        let service = AudioCaptureService(makeDriver: { [factory] in factory!.make() })
        service.onError = { [weak self] error in
            self?.errors.append(error)
            self?.errorThreadWasMain.append(Thread.isMainThread)
        }
        return service
    }

    private func makeBuffer(frames: AVAudioFrameCount, value: Float = 0) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: max(frames, 1))!
        buffer.frameLength = frames
        if frames > 0, let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frames) { channel[index] = value }
        }
        return buffer
    }

    /// 0 ch / 0 Hz, exactly what a stale or absent input node reports.
    private func makeUnusableFormat() -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 0,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        return AVAudioFormat(streamDescription: &asbd)!
    }

    private func flushMainQueue() {
        let flushed = expectation(description: "main queue flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
    }

    private func assertCaptureError(
        _ error: Error,
        is expected: AudioCaptureError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual = error as? AudioCaptureError else {
            XCTFail("expected AudioCaptureError, got \(error)", file: file, line: line)
            return
        }
        switch (actual, expected) {
        case (.busy, .busy),
             (.invalidInput, .invalidInput),
             (.startFailed, .startFailed),
             (.noInputBuffer, .noInputBuffer),
             (.configurationChanged, .configurationChanged):
            break
        default:
            XCTFail("expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    // MARK: 1. Fresh driver per capture

    func testConstructionCreatesNoDriverAndEveryStartCreatesAFreshOne() throws {
        let service = makeService()
        XCTAssertTrue(factory.drivers.isEmpty)

        try service.startRecording()
        XCTAssertEqual(factory.drivers.count, 1)
        XCTAssertEqual(factory.drivers[0].startCount, 1)
        XCTAssertEqual(factory.drivers[0].stopCount, 0)

        _ = try service.stopRecording()
        XCTAssertEqual(factory.drivers[0].stopCount, 1)

        try service.startRecording()
        XCTAssertEqual(factory.drivers.count, 2)
        XCTAssertFalse(factory.drivers[0] === factory.drivers[1])
        XCTAssertEqual(factory.drivers[1].startCount, 1)
        _ = try service.stopRecording()

        try service.startContinuousCapture()
        XCTAssertEqual(factory.drivers.count, 3)
        XCTAssertEqual(factory.drivers[2].startCount, 1)
        service.stopContinuousCapture()

        XCTAssertEqual(factory.drivers.map(\.startCount), [1, 1, 1])
        XCTAssertEqual(factory.drivers.map(\.stopCount), [1, 1, 1])
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: 2. Busy rejection

    func testBusyRejectionLeavesTheFirstCaptureAloneInBothDirections() throws {
        let recordingFirst = makeService()
        try recordingFirst.startRecording()
        XCTAssertThrowsError(try recordingFirst.startContinuousCapture()) { error in
            assertCaptureError(error, is: .busy)
        }
        XCTAssertEqual(factory.drivers.count, 1)
        XCTAssertEqual(factory.drivers[0].stopCount, 0)

        // The first capture is untouched and still accumulating.
        factory.drivers[0].savedOnBuffer?(makeBuffer(frames: 160, value: 0.25))
        let samples = try recordingFirst.stopRecording()
        XCTAssertEqual(samples.count, 160)
        XCTAssertEqual(factory.drivers[0].stopCount, 1)

        let continuousFirst = makeService()
        try continuousFirst.startContinuousCapture()
        XCTAssertThrowsError(try continuousFirst.startRecording()) { error in
            assertCaptureError(error, is: .busy)
        }
        // A duplicate start of the same mode is rejected too: no second tap.
        XCTAssertThrowsError(try continuousFirst.startContinuousCapture()) { error in
            assertCaptureError(error, is: .busy)
        }
        XCTAssertEqual(factory.drivers.count, 2)
        XCTAssertEqual(factory.drivers[1].startCount, 1)
        XCTAssertEqual(factory.drivers[1].stopCount, 0)
        continuousFirst.stopContinuousCapture()
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: 3. Startup failures

    func testDriverStartFailureCleansUpOnceWithoutOnErrorAndAllowsRetry() throws {
        let service = makeService()
        factory.nextStartError = FakeDriverError.hardwareRefused

        XCTAssertThrowsError(try service.startRecording()) { error in
            assertCaptureError(error, is: .startFailed(FakeDriverError.hardwareRefused))
        }
        XCTAssertEqual(factory.drivers.count, 1)
        XCTAssertEqual(factory.drivers[0].stopCount, 1)
        flushMainQueue()
        XCTAssertTrue(errors.isEmpty)

        try service.startRecording()
        XCTAssertEqual(factory.drivers.count, 2)
        _ = try service.stopRecording()
        XCTAssertTrue(errors.isEmpty)
    }

    func testUnusableNativeFormatThrowsCleansUpOnceWithoutOnErrorAndAllowsRetry() throws {
        let service = makeService()
        factory.format = makeUnusableFormat()

        XCTAssertThrowsError(try service.startContinuousCapture()) { error in
            assertCaptureError(error, is: .invalidInput)
        }
        XCTAssertEqual(factory.drivers.count, 1)
        XCTAssertEqual(factory.drivers[0].startCount, 0)
        XCTAssertEqual(factory.drivers[0].stopCount, 1)
        flushMainQueue()
        XCTAssertTrue(errors.isEmpty)

        factory.format = nativeFormat
        try service.startContinuousCapture()
        XCTAssertEqual(factory.drivers.count, 2)
        service.stopContinuousCapture()
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: 4. First-buffer deadline

    func testDigitalZeroBufferSatisfiesTheFirstBufferDeadline() throws {
        let service = makeService()
        try service.startRecording()
        // Closed-lid capture is digital zero; the frame count is what matters.
        factory.last.savedOnBuffer?(makeBuffer(frames: 320, value: 0))
        service.checkFirstBufferDeadline()

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(factory.last.stopCount, 0)
        let samples = try service.stopRecording()
        XCTAssertEqual(samples.count, 320)
    }

    func testZeroFrameBufferDoesNotSatisfyTheDeadlineAndFailsOnceOnMain() throws {
        let service = makeService()
        try service.startRecording()
        factory.last.savedOnBuffer?(makeBuffer(frames: 0))
        service.checkFirstBufferDeadline()

        XCTAssertEqual(errors.count, 1)
        assertCaptureError(errors[0], is: .noInputBuffer)
        XCTAssertEqual(errorThreadWasMain, [true])
        XCTAssertEqual(factory.last.stopCount, 1)

        // The failure is terminal: a second deadline run adds nothing.
        service.checkFirstBufferDeadline()
        flushMainQueue()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(factory.last.stopCount, 1)
    }

    func testNoBufferAtAllFailsWithNoInputBuffer() throws {
        let service = makeService()
        try service.startContinuousCapture()
        service.checkFirstBufferDeadline()

        XCTAssertEqual(errors.count, 1)
        assertCaptureError(errors[0], is: .noInputBuffer)
        XCTAssertEqual(factory.last.stopCount, 1)
    }

    // MARK: 5. Configuration change

    func testConfigurationChangeDiscardsTheUtteranceAndStopRecordingThrows() throws {
        let service = makeService()
        try service.startRecording()
        factory.last.savedOnBuffer?(makeBuffer(frames: 8000, value: 0.5))

        factory.last.savedOnConfigurationChange?()
        // Repeat events are latched once.
        factory.last.savedOnConfigurationChange?()

        XCTAssertThrowsError(try service.stopRecording()) { error in
            assertCaptureError(error, is: .configurationChanged)
        }
        service.checkFirstBufferDeadline()
        flushMainQueue()

        XCTAssertEqual(errors.count, 1)
        assertCaptureError(errors[0], is: .configurationChanged)
        XCTAssertEqual(factory.last.stopCount, 1)

        // Nothing survives for insertion: a later stop yields no audio.
        XCTAssertEqual(try service.stopRecording(), [])
    }

    // MARK: 6. Notification thread

    func testConfigurationChangeOnBackgroundQueueStillThrowsFromStopOnMain() throws {
        let service = makeService()
        try service.startRecording()
        factory.last.savedOnBuffer?(makeBuffer(frames: 1600, value: 0.1))

        let driver = factory.last
        let latched = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            driver.savedOnConfigurationChange?()
            latched.signal()
        }
        XCTAssertEqual(latched.wait(timeout: .now() + 5), .success)

        // Main has not yet drained the queued cleanup.
        XCTAssertThrowsError(try service.stopRecording()) { error in
            assertCaptureError(error, is: .configurationChanged)
        }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(driver.stopRanOnMainThread, [true])

        flushMainQueue()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(driver.stopRanOnMainThread, [true])
    }

    // MARK: 7. Stopped captures are inert

    func testNormalStopAndCancelBeforeTheDeadlineRaiseNoError() throws {
        let stopped = makeService()
        try stopped.startRecording()
        _ = try stopped.stopRecording()
        stopped.checkFirstBufferDeadline()

        let cancelled = makeService()
        try cancelled.startRecording()
        factory.last.savedOnBuffer?(makeBuffer(frames: 480, value: 0.3))
        cancelled.cancelRecording()
        cancelled.checkFirstBufferDeadline()

        flushMainQueue()
        XCTAssertTrue(errors.isEmpty)
    }

    func testLateCallbacksFromAStoppedCaptureCannotTouchTheNextCapture() throws {
        let service = makeService()
        try service.startRecording()
        let stale = factory.drivers[0]
        _ = try service.stopRecording()

        try service.startRecording()
        let fresh = factory.drivers[1]

        stale.savedOnBuffer?(makeBuffer(frames: 4000, value: 0.9))
        stale.savedOnConfigurationChange?()
        flushMainQueue()

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(fresh.stopCount, 0)

        // The stale buffer did not satisfy the new capture's readiness.
        service.checkFirstBufferDeadline()
        XCTAssertEqual(errors.count, 1)
        assertCaptureError(errors[0], is: .noInputBuffer)
        XCTAssertEqual(fresh.stopCount, 1)
        XCTAssertEqual(stale.stopCount, 1)
    }

    // MARK: 8. Configuration failure during start

    func testConfigurationFailureDuringDriverStartThrowsWithoutOnError() throws {
        let service = makeService()
        factory.fireConfigurationChangeDuringNextStart = true

        XCTAssertThrowsError(try service.startRecording()) { error in
            assertCaptureError(error, is: .configurationChanged)
        }
        XCTAssertEqual(factory.drivers[0].stopCount, 1)
        flushMainQueue()
        XCTAssertTrue(errors.isEmpty)

        try service.startRecording()
        XCTAssertEqual(factory.drivers.count, 2)
        _ = try service.stopRecording()
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: 9. Callback snapshot

    func testSwitchingOnErrorAfterAFailureCannotReachTheLaterConsumer() throws {
        var first: [Error] = []
        var second: [Error] = []
        let service = AudioCaptureService(makeDriver: { [factory] in factory!.make() })
        service.onError = { first.append($0) }

        try service.startRecording()
        factory.last.savedOnConfigurationChange?()
        service.onError = { second.append($0) }

        XCTAssertThrowsError(try service.stopRecording()) { error in
            assertCaptureError(error, is: .configurationChanged)
        }
        flushMainQueue()
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty)
    }

    func testStoppingAndRestartingDoesNotRetainTheOldConsumerThroughCallbacks() throws {
        let service = AudioCaptureService(makeDriver: { [factory] in factory!.make() })
        weak var weakConsumer: Consumer?

        try autoreleasepool {
            let consumer = Consumer()
            weakConsumer = consumer
            service.onError = { _ in _ = consumer }
            service.onSamples = { _ in _ = consumer }
            try service.startRecording()
            _ = try service.stopRecording()
            service.onError = nil
            service.onSamples = nil
        }

        try service.startRecording()
        _ = try service.stopRecording()
        XCTAssertNil(weakConsumer)
    }

    // MARK: F1. Callbacks in flight when stop closes the gate

    func testCallbacksArrivingDuringStopCannotEraseTheCapturedAudio() throws {
        let service = makeService()
        try service.startRecording()
        let driver = factory.last
        driver.savedOnBuffer?(makeBuffer(frames: 8000, value: 0.4))

        // Both events land after stopRecording closed the gate but while the
        // Capture is still live, which is the ordering a real in-flight
        // notification produces. Neither may touch the finished utterance.
        let lateBuffer = makeBuffer(frames: 320, value: 0.9)
        driver.duringStop = { late in
            late.savedOnBuffer?(lateBuffer)
            late.savedOnConfigurationChange?()
        }

        let samples = try service.stopRecording()
        XCTAssertEqual(samples.count, 8000)
        XCTAssertEqual(driver.stopCount, 1)

        flushMainQueue()
        XCTAssertTrue(errors.isEmpty)

        // The stop was clean, so the service is free for the next press.
        try service.startRecording()
        XCTAssertEqual(factory.drivers.count, 2)
        _ = try service.stopRecording()
    }

    func testAConfigurationEventDuringCancelIsIgnored() throws {
        let service = makeService()
        try service.startRecording()
        let driver = factory.last
        driver.savedOnBuffer?(makeBuffer(frames: 1600, value: 0.2))
        driver.duringStop = { late in late.savedOnConfigurationChange?() }

        service.cancelRecording()
        flushMainQueue()

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(try service.stopRecording(), [])
    }

    // MARK: F2. Failure delivered before stop is still the stop result

    func testFailureDeliveredBeforeStopIsStillThrownAndAcknowledgedOnce() throws {
        var received: [Error] = []
        let service = AudioCaptureService(makeDriver: { [factory] in factory!.make() })
        // Records only: it neither cancels nor stops, so the service alone has
        // to keep the terminal result alive.
        service.onError = { received.append($0) }

        try service.startRecording()
        let driver = factory.last
        driver.savedOnBuffer?(makeBuffer(frames: 8000, value: 0.3))
        driver.savedOnConfigurationChange?()
        flushMainQueue()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(driver.stopCount, 1)

        XCTAssertThrowsError(try service.stopRecording()) { error in
            assertCaptureError(error, is: .configurationChanged)
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(driver.stopCount, 1)

        // That throw acknowledged it: a further stop is a no-op and the next
        // capture starts cleanly.
        XCTAssertEqual(try service.stopRecording(), [])
        try service.startRecording()
        XCTAssertEqual(factory.drivers.count, 2)
        _ = try service.stopRecording()
        XCTAssertEqual(received.count, 1)
    }

    func testFailureWithNoErrorHandlerIsStillThrownByStop() throws {
        let service = AudioCaptureService(makeDriver: { [factory] in factory!.make() })
        // onError is deliberately never assigned.
        try service.startRecording()
        factory.last.savedOnConfigurationChange?()
        flushMainQueue()

        XCTAssertEqual(factory.last.stopCount, 1)
        XCTAssertThrowsError(try service.stopRecording()) { error in
            assertCaptureError(error, is: .configurationChanged)
        }
        XCTAssertEqual(try service.stopRecording(), [])

        try service.startRecording()
        XCTAssertEqual(factory.drivers.count, 2)
        _ = try service.stopRecording()
    }

    func testReentrantCancelInsideOnErrorAcknowledgesTheFailure() throws {
        var received: [Error] = []
        let service = AudioCaptureService(makeDriver: { [factory] in factory!.make() })
        let box = ServiceBox()
        box.service = service
        service.onError = { error in
            received.append(error)
            box.service?.cancelRecording()
        }

        try service.startRecording()
        let driver = factory.last
        driver.savedOnBuffer?(makeBuffer(frames: 4000, value: 0.5))
        driver.savedOnConfigurationChange?()
        flushMainQueue()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(driver.stopCount, 1)

        // The callback acknowledged it, so stop reports no recording and the
        // next start is not rejected as busy.
        XCTAssertEqual(try service.stopRecording(), [])
        try service.startRecording()
        XCTAssertEqual(factory.drivers.count, 2)
        _ = try service.stopRecording()
        XCTAssertEqual(received.count, 1)
    }

    func testDeliveredFailureSurvivesARepeatedDeadlineWithoutASecondCallback() throws {
        let service = makeService()
        try service.startRecording()
        service.checkFirstBufferDeadline()

        XCTAssertEqual(errors.count, 1)
        assertCaptureError(errors[0], is: .noInputBuffer)

        // The failed capture is retained until acknowledged, so this repetition
        // exercises the claim flag on a live record rather than an empty slot.
        service.checkFirstBufferDeadline()
        flushMainQueue()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(factory.last.stopCount, 1)

        XCTAssertThrowsError(try service.stopRecording()) { error in
            assertCaptureError(error, is: .noInputBuffer)
        }
        XCTAssertEqual(errors.count, 1)
    }

    // MARK: F4. Saved deadline from a stopped capture

    func testASavedDeadlineFromAStoppedCaptureIsInert() throws {
        let service = makeService()
        try service.startRecording()
        let staleDeadline = try XCTUnwrap(service.scheduledFirstBufferDeadline())
        _ = try service.stopRecording()

        try service.startRecording()
        let fresh = factory.last

        // This is the exact item production scheduled for the stopped capture.
        // Invoking it proves cancellation and weak ownership. It does not by
        // itself prove the identity guard, which needs a retained in-flight
        // capture; the configuration-event tests above cover that path.
        XCTAssertTrue(staleDeadline.isCancelled)
        staleDeadline.perform()
        flushMainQueue()
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(fresh.stopCount, 0)

        // The new capture still owns a working deadline of its own.
        service.checkFirstBufferDeadline()
        XCTAssertEqual(errors.count, 1)
        assertCaptureError(errors[0], is: .noInputBuffer)
        XCTAssertEqual(fresh.stopCount, 1)
    }

    // MARK: F4. Real MicAudioSource lifetime

    @MainActor
    func testMicAudioSourceStopClearsBothCallbackSetsAndReleasesTheAdapter() async throws {
        let service = AudioCaptureService(makeDriver: { [factory] in factory!.make() })
        var samplesSeen = 0
        weak var weakAdapter: MicAudioSource?

        var adapter: MicAudioSource? = MicAudioSource(service: service)
        weakAdapter = adapter
        adapter?.onSamples = { samplesSeen += $0.count }
        adapter?.onError = { _ in }

        try await adapter!.start()

        // Positive control: the adapter is alive while the test holds it.
        XCTAssertNotNil(weakAdapter)
        XCTAssertNotNil(service.onSamples)
        XCTAssertNotNil(service.onError)

        factory.last.savedOnBuffer?(makeBuffer(frames: 160, value: 0.1))
        XCTAssertEqual(samplesSeen, 160)

        adapter?.stop()
        XCTAssertNil(service.onSamples)
        XCTAssertNil(service.onError)
        XCTAssertNil(adapter?.onSamples)
        XCTAssertNil(adapter?.onError)
        XCTAssertEqual(factory.last.stopCount, 1)

        adapter = nil
        XCTAssertNil(weakAdapter)
    }

    // MARK: 10. Pure tap classification

    func testTapClassificationBoundaries() {
        XCTAssertTrue(isTranslationTap(elapsed: 0.299, captureFailed: false))
        XCTAssertFalse(isTranslationTap(elapsed: 0.300, captureFailed: false))
        XCTAssertFalse(isTranslationTap(elapsed: 0.301, captureFailed: false))
        XCTAssertFalse(isTranslationTap(elapsed: 0.0, captureFailed: true))
        XCTAssertFalse(isTranslationTap(elapsed: 0.299, captureFailed: true))
        XCTAssertFalse(isTranslationTap(elapsed: 5.0, captureFailed: true))
    }

    /// The release instant is sampled on entry to `handleHotkeyRelease`, before
    /// `stopRecording()` tears the engine down. Teardown that lands after the
    /// snapshot therefore cannot promote a tap into a hold. Only the call-site
    /// ordering can prove where the clock is read; this pins the arithmetic the
    /// ordering has to produce.
    func testTeardownAfterTheReleaseSnapshotCannotTurnATapIntoAHold() {
        let keyDown: TimeInterval = 1_000.0
        let releaseSnapshot: TimeInterval = keyDown + 0.299
        let afterTeardown: TimeInterval = releaseSnapshot + 0.15

        XCTAssertTrue(isTranslationTap(elapsed: releaseSnapshot - keyDown, captureFailed: false))
        XCTAssertFalse(isTranslationTap(elapsed: afterTeardown - keyDown, captureFailed: false))
    }
}
