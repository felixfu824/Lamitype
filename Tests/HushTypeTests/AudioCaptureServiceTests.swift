import AVFoundation
import CoreAudio
import XCTest
@testable import HushType

// MARK: - Fakes

/// Stand-in for `AVEngineCaptureDriver`. No `AVAudioEngine`, no microphone,
/// no permission prompt. Saved callbacks are deliberately retained after
/// `stop()` so a test can fire a late buffer or configuration change.
private final class FakeCaptureDriver: CaptureDriver {
    var format: AVAudioFormat
    var startError: Error?
    var runningOnOriginalInput = false
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

    private(set) var formatReads = 0
    var inputFormat: AVAudioFormat {
        formatReads += 1
        return format
    }

    func stillRunningOnOriginalInput(format: AVAudioFormat) -> Bool {
        runningOnOriginalInput && self.format == format
    }

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

    func testFormatWarmupLeavesInputStoppedAndPressUsesCurrentRoute() throws {
        let service = makeService()
        factory.format = makeUnusableFormat()
        service.warmRecordingFormat()
        let warm = factory.last
        XCTAssertEqual(warm.formatReads, 1)
        XCTAssertEqual(warm.startCount, 0)
        XCTAssertNil(warm.savedOnBuffer)

        factory.format = nativeFormat
        try service.startRecording()
        let active = factory.last
        XCTAssertFalse(active === warm)
        XCTAssertEqual(active.startCount, 1)
        active.savedOnBuffer?(makeBuffer(frames: 320, value: 0.25))
        XCTAssertEqual(try service.stopRecording(), Array(repeating: Float(0.25), count: 320))
    }

    func testFormatWarmupDuringCaptureDoesNotOpenAnotherDriver() throws {
        let service = makeService()
        try service.startRecording()
        service.warmRecordingFormat()
        XCTAssertEqual(factory.drivers.count, 1)
        XCTAssertEqual(factory.last.stopCount, 0)
        _ = try service.stopRecording()
    }

    private func makeBuffer(frames: AVAudioFrameCount, value: Float = 0, format: AVAudioFormat? = nil) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format ?? nativeFormat, frameCapacity: max(frames, 1))!
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
             (.silentInput, .silentInput),
             (.configurationChanged, .configurationChanged):
            break
        default:
            XCTFail("expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    // MARK: - Standard dictation duration cap

    func testStandardDictationCapFinishesAtTenMinutesWithoutAnotherBuffer() throws {
        var uptime: TimeInterval = 42
        var checks: [(TimeInterval, DispatchWorkItem)] = []
        let service = AudioCaptureService(makeDriver: factory.make, now: { uptime },
                                          scheduleDurationCheck: { checks.append(($0, $1)) })
        var finishedSamples: [Float]?
        try service.startRecording(limitSeconds: AudioCaptureService.standardDictationLimitSeconds,
                                   onDurationLimit: {
            finishedSamples = try? service.finishRecording(reason: .durationCap).samples
        })
        factory.last.savedOnBuffer?(makeBuffer(frames: 5000, value: 0.25))

        XCTAssertEqual(checks.first?.0, 600)
        uptime = 641
        checks.removeFirst().1.perform()
        XCTAssertNil(finishedSamples)
        XCTAssertEqual(factory.last.stopCount, 0)
        XCTAssertEqual(checks.first?.0, 1)

        uptime = 642
        checks.removeFirst().1.perform()
        XCTAssertEqual(finishedSamples, Array(repeating: 0.25, count: 5000))
        XCTAssertEqual(factory.last.stopCount, 1)
        XCTAssertTrue(checks.isEmpty)
    }

    func testReleaseBeforeCapPreservesAudioAndRetiresDeadline() throws {
        var uptime: TimeInterval = 42
        var checks: [DispatchWorkItem] = []
        let service = AudioCaptureService(makeDriver: factory.make, now: { uptime },
                                          scheduleDurationCheck: { _, check in checks.append(check) })
        var capCount = 0
        try service.startRecording(limitSeconds: AudioCaptureService.standardDictationLimitSeconds,
                                   onDurationLimit: { capCount += 1 })
        factory.last.savedOnBuffer?(makeBuffer(frames: 5000, value: 0.5))

        let releaseUptime: TimeInterval = 641
        uptime = 642
        XCTAssertFalse(service.recordingDurationElapsed(at: releaseUptime))
        XCTAssertTrue(service.recordingDurationElapsed(at: uptime))
        XCTAssertEqual(try service.stopRecording(), Array(repeating: 0.5, count: 5000))
        XCTAssertEqual(factory.last.stopCount, 1)
        let oldCheck = checks.removeFirst()
        XCTAssertTrue(oldCheck.isCancelled)
        try service.startRecording(limitSeconds: AudioCaptureService.standardDictationLimitSeconds,
                                   onDurationLimit: { capCount += 1 })
        oldCheck.perform()
        XCTAssertEqual(capCount, 0)
        XCTAssertEqual(factory.last.stopCount, 0)
        service.cancelRecording(reason: .userDiscarded)
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

    func testOutputConfigurationChangeRebuildsTapAndPreservesTheUtterance() throws {
        let service = makeService()
        try service.startRecording()
        let old = factory.last
        let oldDeadline = try XCTUnwrap(service.scheduledFirstBufferDeadline())
        old.savedOnBuffer?(makeBuffer(frames: 800, value: 0.25))

        old.savedOnConfigurationChange?()
        old.savedOnConfigurationChange?()
        flushMainQueue()

        XCTAssertEqual(factory.drivers.count, 2)
        XCTAssertEqual(old.stopRanOnMainThread, [true])
        XCTAssertTrue(oldDeadline.isCancelled)
        oldDeadline.perform()
        old.savedOnBuffer?(makeBuffer(frames: 500, value: 0.9))
        old.savedOnConfigurationChange?()
        let replacement = factory.last
        replacement.savedOnBuffer?(makeBuffer(frames: 320, value: 0.5))
        service.checkFirstBufferDeadline()
        flushMainQueue()

        let result = try service.finishRecording()
        XCTAssertFalse(result.interrupted)
        XCTAssertEqual(result.samples, Array(repeating: 0.25, count: 800) + Array(repeating: 0.5, count: 320))
        XCTAssertEqual(replacement.stopCount, 1)
        XCTAssertTrue(errors.isEmpty)
    }

    func testProfileSwitchRebuildsConverterForTheNewRate() throws {
        let service = makeService()
        try service.startRecording()
        let old = factory.last
        old.savedOnBuffer?(makeBuffer(frames: 800, value: 0.25))
        let newFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 32000, channels: 1, interleaved: false
        ))
        factory.format = newFormat
        old.savedOnConfigurationChange?()
        flushMainQueue()

        factory.last.savedOnBuffer?(makeBuffer(frames: 1600, value: 0.75, format: newFormat))
        service.checkFirstBufferDeadline()
        let result = try service.finishRecording()
        XCTAssertFalse(result.interrupted)
        XCTAssertEqual(result.samples.count, 1600)
        XCTAssertEqual(Array(result.samples.prefix(800)), Array(repeating: 0.25, count: 800))
        XCTAssertEqual(try XCTUnwrap(result.samples.last), 0.75, accuracy: 0.01)
        XCTAssertTrue(errors.isEmpty)
    }

    func testDirectBluetoothInputRequiresTheVerifiedBuiltInOutputRoute() {
        XCTAssertTrue(BluetoothInputDriver.supportsOutput(transport: kAudioDeviceTransportTypeBuiltIn))
        for transport in [nil, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                          kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeUSB] {
            XCTAssertFalse(BluetoothInputDriver.supportsOutput(transport: transport))
        }
    }

    func testTapWhileReplacementHasNoSamplesRetiresBothDrivers() throws {
        let service = makeService()
        try service.startRecording()
        factory.last.savedOnBuffer?(makeBuffer(frames: 1600, value: 0.25))
        factory.last.savedOnConfigurationChange?()
        flushMainQueue()
        let recording = try service.finishRecording(isTap: true)
        XCTAssertFalse(recording.interrupted)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(factory.drivers.map(\.stopCount), [1, 1])
        try service.startRecording()
        _ = try service.finishRecording(isTap: true)
    }

    func testRunningStartupInputKeepsItsFirstSamplesAndStillRecoversOnLaterChanges() throws {
        let service = makeService()
        try service.startRecording()
        let first = factory.last
        first.runningOnOriginalInput = true
        first.savedOnConfigurationChange?()
        first.savedOnBuffer?(makeBuffer(frames: 320, value: 0.25))
        flushMainQueue()
        XCTAssertEqual(factory.drivers.count, 1)
        service.checkFirstBufferDeadline()
        first.savedOnConfigurationChange?()
        flushMainQueue()
        XCTAssertEqual(factory.drivers.count, 2)
        factory.last.savedOnBuffer?(makeBuffer(frames: 320, value: 0.5))
        let recording = try service.finishRecording()
        XCTAssertFalse(recording.interrupted)
        XCTAssertEqual(recording.samples, Array(repeating: 0.25, count: 320) + Array(repeating: 0.5, count: 320))
        XCTAssertTrue(errors.isEmpty)
    }

    func testRunningButSilentStartupGraphStillReopensAtOriginalDeadline() throws {
        let service = makeService()
        try service.startRecording()
        factory.last.runningOnOriginalInput = true
        factory.last.savedOnConfigurationChange?()
        flushMainQueue()
        XCTAssertEqual(factory.drivers.count, 1)
        service.checkFirstBufferDeadline()
        XCTAssertEqual(factory.drivers.count, 2)
        service.checkFirstBufferDeadline()
        XCTAssertEqual(errors.count, 1)
        assertCaptureError(errors[0], is: .configurationChanged)
    }

    func testStartupNotificationQueuedAtDeadlineCannotLeaveCaptureWithoutAWatchdog() throws {
        let service = makeService()
        try service.startRecording()
        factory.last.runningOnOriginalInput = true
        factory.last.savedOnConfigurationChange?()
        service.checkFirstBufferDeadline()
        flushMainQueue()
        XCTAssertEqual(factory.drivers.count, 2)
        service.checkFirstBufferDeadline()
        XCTAssertEqual(errors.count, 1)
        assertCaptureError(errors[0], is: .configurationChanged)
    }

    func testReplacementRebuildsTapAfterFormatChangesDuringStart() throws {
        let service = makeService()
        try service.startRecording()
        factory.last.savedOnBuffer?(makeBuffer(frames: 320, value: 0.25))
        factory.nextStartError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        factory.last.savedOnConfigurationChange?()
        flushMainQueue()
        XCTAssertEqual(factory.drivers.count, 3)
        factory.last.savedOnBuffer?(makeBuffer(frames: 320, value: 0.5))
        let recording = try service.finishRecording()
        XCTAssertFalse(recording.interrupted)
        XCTAssertEqual(recording.samples, Array(repeating: 0.25, count: 320) + Array(repeating: 0.5, count: 320))
        XCTAssertTrue(errors.isEmpty)
    }

    func testSilentRecordingThresholdAndQuietSpeech() throws {
        let service = makeService()
        for level: Float in [0, 0.00001] {
            try service.startRecording()
            factory.last.savedOnBuffer?(makeBuffer(frames: 16_000, value: level))
            XCTAssertThrowsError(try service.finishRecording()) { self.assertCaptureError($0, is: .silentInput) }
        }
        try service.startRecording()
        factory.last.savedOnBuffer?(makeBuffer(frames: 15_999))
        XCTAssertEqual(try service.stopRecording().count, 15_999)
        try service.startRecording()
        factory.last.savedOnBuffer?(makeBuffer(frames: 32_000))
        factory.last.savedOnBuffer?(makeBuffer(frames: 320, value: -0.0001))
        XCTAssertEqual(try service.stopRecording().count, 32_320)
    }

    func testReleaseBeforeQueuedRecoveryReturnsTheRecordedSamples() throws {
        let service = makeService()
        try service.startRecording()
        let old = factory.last
        old.savedOnBuffer?(makeBuffer(frames: 1600, value: 0.125))

        let notified = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            old.savedOnConfigurationChange?()
            notified.signal()
        }
        XCTAssertEqual(notified.wait(timeout: .now() + 5), .success)

        let result = try service.finishRecording()
        XCTAssertTrue(result.interrupted)
        XCTAssertEqual(result.samples, Array(repeating: 0.125, count: 1600))
        XCTAssertEqual(errors.count, 1)
        assertCaptureError(errors[0], is: .configurationChanged)
        XCTAssertEqual(old.stopRanOnMainThread, [true])

        flushMainQueue()
        XCTAssertEqual(factory.drivers.count, 1)
        XCTAssertEqual(errors.count, 1)
    }

    func testReplacementWithNoUsableSamplesFailsButKeepsPriorAudio() throws {
        let service = makeService()
        try service.startRecording()
        factory.last.savedOnBuffer?(makeBuffer(frames: 1600, value: 0.5))
        factory.last.savedOnConfigurationChange?()
        flushMainQueue()

        service.checkFirstBufferDeadline()
        XCTAssertTrue(service.hasInterruptedRecording)
        XCTAssertEqual(errors.count, 1)
        assertCaptureError(errors[0], is: .configurationChanged)
        XCTAssertEqual(factory.drivers.map(\.stopCount), [1, 1])
        XCTAssertEqual(try service.stopRecording(), Array(repeating: 0.5, count: 1600))
    }

    func testRepeatedNotificationBeforeRecoveryDoesNotLoop() throws {
        let service = makeService()
        try service.startContinuousCapture()
        factory.fireConfigurationChangeDuringNextStart = true
        factory.last.savedOnConfigurationChange?()
        flushMainQueue()
        flushMainQueue()

        XCTAssertEqual(factory.drivers.count, 2)
        XCTAssertEqual(factory.drivers.map(\.stopCount), [1, 1])
        XCTAssertEqual(errors.count, 1)
        assertCaptureError(errors[0], is: .configurationChanged)
        service.stopContinuousCapture()
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
        cancelled.cancelRecording(reason: .shortcutChord)
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

    // MARK: 8. Configuration change during start

    func testConfigurationChangeDuringDriverStartRecoversWithoutOnError() throws {
        let service = makeService()
        factory.fireConfigurationChangeDuringNextStart = true
        try service.startRecording()
        flushMainQueue()

        XCTAssertEqual(factory.drivers.count, 2)
        XCTAssertEqual(factory.drivers[0].stopCount, 1)
        factory.last.savedOnBuffer?(makeBuffer(frames: 500, value: 0.5))
        XCTAssertEqual(try service.stopRecording().count, 500)
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

        service.cancelRecording(reason: .shortcutChord)
        flushMainQueue()

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(try service.stopRecording(), [])
    }

    // MARK: F2. Failure delivered before stop is still the stop result

    func testFailedRestartIsDeliveredOnceAndReleaseReturnsPriorAudio() throws {
        var received: [Error] = []
        let service = AudioCaptureService(makeDriver: { [factory] in factory!.make() })
        // Records only: it neither cancels nor stops, so the service alone has
        // to keep the terminal result alive.
        service.onError = { received.append($0) }

        try service.startRecording()
        let driver = factory.last
        driver.savedOnBuffer?(makeBuffer(frames: 8000, value: 0.3))
        factory.nextStartError = FakeDriverError.hardwareRefused
        driver.savedOnConfigurationChange?()
        flushMainQueue()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(driver.stopCount, 1)

        XCTAssertEqual(try service.stopRecording(), Array(repeating: 0.3, count: 8000))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(try service.stopRecording(), [])
        try service.startRecording()
        XCTAssertEqual(factory.drivers.count, 3)
        _ = try service.stopRecording()
        XCTAssertEqual(received.count, 1)
    }

    func testFailureWithNoErrorHandlerIsStillThrownByStop() throws {
        let service = AudioCaptureService(makeDriver: { [factory] in factory!.make() })
        // onError is deliberately never assigned.
        try service.startRecording()
        factory.nextStartError = FakeDriverError.hardwareRefused
        factory.last.savedOnConfigurationChange?()
        flushMainQueue()

        XCTAssertEqual(factory.last.stopCount, 1)
        XCTAssertThrowsError(try service.stopRecording()) { error in
            assertCaptureError(error, is: .configurationChanged)
        }
        XCTAssertEqual(try service.stopRecording(), [])

        try service.startRecording()
        XCTAssertEqual(factory.drivers.count, 3)
        _ = try service.stopRecording()
    }

    func testReentrantCancelInsideOnErrorAcknowledgesTheFailure() throws {
        var received: [Error] = []
        let service = AudioCaptureService(makeDriver: { [factory] in factory!.make() })
        let box = ServiceBox()
        box.service = service
        service.onError = { error in
            received.append(error)
            box.service?.cancelRecording(reason: .shortcutChord)
        }

        try service.startRecording()
        let driver = factory.last
        driver.savedOnBuffer?(makeBuffer(frames: 4000, value: 0.5))
        factory.nextStartError = FakeDriverError.hardwareRefused
        driver.savedOnConfigurationChange?()
        flushMainQueue()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(driver.stopCount, 1)

        // The callback acknowledged it, so stop reports no recording and the
        // next start is not rejected as busy.
        XCTAssertEqual(try service.stopRecording(), [])
        try service.startRecording()
        XCTAssertEqual(factory.drivers.count, 3)
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
