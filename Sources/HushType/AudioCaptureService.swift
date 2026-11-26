import AVFoundation
import CoreAudio
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "audio")

struct DictationCaptureTiming {
    let keyDown: TimeInterval
    let admitted: TimeInterval

    var pressUptimeMs: Int64 { Int64(keyDown * 1000) }

    static func milliseconds(from start: TimeInterval, to end: TimeInterval) -> Double {
        (end - start) * 1000
    }
}

enum RecordingCancellationReason: String {
    case shortcutChord, hotkeyInterrupted, secureInput, systemSleep, applicationQuit, userDiscarded
    case busy, invalidInput, startFailed, noInputBuffer, silentInput, configurationChanged, captureFailure

    init(error: Error) {
        guard let error = error as? AudioCaptureError else { self = .captureFailure; return }
        switch error {
        case .busy: self = .busy
        case .invalidInput: self = .invalidInput
        case .startFailed: self = .startFailed
        case .noInputBuffer: self = .noInputBuffer
        case .silentInput: self = .silentInput
        case .configurationChanged: self = .configurationChanged
        }
    }
}

// MARK: - Errors

/// Every failure `AudioCaptureService` reports, thrown from the synchronous
/// entry points or delivered once through `onError` after a successful start.
enum AudioCaptureError: LocalizedError {
    /// A capture is already running; the second start is rejected untouched.
    case busy
    /// The fresh input node reported an unusable native format.
    case invalidInput
    /// The hardware refused to start. The underlying error is logged, never shown.
    case startFailed(Error)
    /// No positive-frame input buffer arrived within the first-buffer deadline.
    case noInputBuffer
    /// PCM arrived for at least a second, but stayed at the digital noise floor.
    case silentInput
    /// The input could not resume after an audio configuration change.
    case configurationChanged

    var errorDescription: String? {
        switch self {
        case .busy:
            return L10n.string(
                "error.audio_capture.busy",
                fallback: "Microphone capture is already active."
            )
        case .invalidInput:
            return L10n.string(
                "error.audio_capture.invalid_input",
                fallback: "No usable microphone was found. Check your audio input in System Settings and try again."
            )
        case .startFailed:
            return L10n.string(
                "error.audio_capture.start_failed",
                fallback: "Could not start the microphone. Check your audio input in System Settings and try again."
            )
        case .noInputBuffer:
            return L10n.string(
                "error.audio_capture.no_input_buffer",
                fallback: "No audio was received from the microphone. Check your audio input in System Settings and try again."
            )
        case .silentInput:
            return L10n.string("error.audio_capture.silent_input", fallback: "The microphone was silent. Check your input or mute switch and try again.")
        case .configurationChanged:
            return L10n.string(
                "error.audio_capture.configuration_changed",
                fallback: "The audio configuration changed and the microphone stopped. Try dictating again."
            )
        }
    }

    static var interruptedRecordingMessage: String {
        L10n.string(
            "notice.audio_capture.interrupted_partial",
            fallback: "The microphone stopped after an audio configuration change. Release the shortcut to use the audio already recorded."
        )
    }
}

// MARK: - Capture driver seam

/// One capture session's hardware backend. This is the ONLY injected seam in
/// `AudioCaptureService`: tests supply a fake so no `AVAudioEngine` or
/// microphone is ever instantiated. The driver owns nothing but hardware; the
/// service owns conversion, the failure latch, the first-buffer deadline and
/// sample accumulation.
protocol CaptureDriver: AnyObject {
    /// Native output format of this driver's input node, read before `start`.
    var inputFormat: AVAudioFormat { get }

    /// On the main queue, verify that a startup notification left the original
    /// hardware path running at its original format.
    func stillRunningOnOriginalInput(format: AVAudioFormat) -> Bool

    /// Install the tap and the configuration observer, then start the engine.
    /// Any partial setup is torn down before this throws.
    ///
    /// `onConfigurationChange` is invoked synchronously on whatever thread
    /// surfaces the notification. The driver never performs lifecycle work inside it.
    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onConfigurationChange: @escaping () -> Void
    ) throws

    /// Idempotent. Releases observer, tap and engine.
    func stop()
}

extension CaptureDriver {
    func stillRunningOnOriginalInput(format: AVAudioFormat) -> Bool { false }
}

/// Production driver: one fresh `AVAudioEngine` per capture.
///
/// A permanent engine is what broke device switching. Its input node kept
/// returning the format cached from the previous device, so the next tap was
/// installed with a stale format and either threw inside `installTap` or
/// delivered no audio at all. A per-capture engine never carries that state.
final class AVEngineCaptureDriver: CaptureDriver {
    private let originalDevice = BluetoothInputDriver.defaultInputDevice
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var observerToken: NSObjectProtocol?

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func stillRunningOnOriginalInput(format: AVAudioFormat) -> Bool {
        guard engine.isRunning, let originalDevice, originalDevice != kAudioObjectUnknown,
              originalDevice == BluetoothInputDriver.defaultInputDevice else { return false }
        return inputFormat == format
    }

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onConfigurationChange: @escaping () -> Void
    ) throws {
        let input = engine.inputNode
        let sampleRate = input.outputFormat(forBus: 0).sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { throw AudioCaptureError.invalidInput }
        // A fixed frame count queues a quarter second at 16 kHz. Request the
        // same duration across routes so a headset tap can deliver sooner.
        let bufferSize = AVAudioFrameCount(max(1, (sampleRate / 10).rounded()))

        // Scoped to THIS engine object, registered before start so a change
        // that lands during startup is latched rather than lost.
        observerToken = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            onConfigurationChange()
        }

        // format: nil adopts the bus format instead of imposing a cached one.
        input.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { buffer, _ in
            onBuffer(buffer)
        }
        tapInstalled = true

        do {
            let engineStart = ProcessInfo.processInfo.systemUptime
            try engine.start()
            let engineStarted = ProcessInfo.processInfo.systemUptime
            log.info("Audio engine started: startUptimeMs=\(engineStart * 1000, privacy: .public) durationMs=\(DictationCaptureTiming.milliseconds(from: engineStart, to: engineStarted), privacy: .public)")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
            self.observerToken = nil
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }
}

// MARK: - Service

/// Microphone capture for push-to-talk dictation and live captions.
///
/// One `Capture` per session owns its callbacks and accumulated audio.
/// Each engine attachment has its own identity, so callbacks from a replaced
/// tap cannot feed the replacement or trigger another restart.
///
/// Lifecycle, the first-buffer deadline and all hardware setup/teardown are
/// main-queue confined.
final class AudioCaptureService {
    static let standardDictationLimitSeconds: TimeInterval = 10 * 60

    enum Mode {
        case recording
        case continuous
    }

    private let makeDriver: (Mode) -> any CaptureDriver
    private let now: () -> TimeInterval
    private let scheduleDurationCheck: (TimeInterval, DispatchWorkItem) -> Void

    private static func scheduleOnMain(after delay: TimeInterval, work: DispatchWorkItem) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The one live capture, main-queue confined.
    private var current: Capture?

    /// Called on each audio buffer with the current RMS level (0.0-1.0).
    /// Push-to-talk only. Fires on the CoreAudio IO thread.
    var onRMSLevel: ((Float) -> Void)?

    /// Called on each audio buffer with the converted 16kHz mono Float32
    /// samples. Fires on the CoreAudio IO thread. Continuous capture only.
    var onSamples: (([Float]) -> Void)?

    /// Terminal-failure callback, delivered on the main queue exactly once per
    /// capture, after the hardware is released. A synchronous startup failure
    /// throws instead; a normal stop, a cancel and a busy rejection never call
    /// this. The value is snapshotted at start, so reassigning it later can
    /// never route an older capture's failure to a newer consumer.
    var onError: ((Error) -> Void)?

    init(makeDriver: @escaping () -> any CaptureDriver,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         scheduleDurationCheck: @escaping (TimeInterval, DispatchWorkItem) -> Void = AudioCaptureService.scheduleOnMain) {
        self.makeDriver = { _ in makeDriver() }
        self.now = now
        self.scheduleDurationCheck = scheduleDurationCheck
    }

    init() {
        BluetoothInputDriver.warmDeviceLookup()
        now = { ProcessInfo.processInfo.systemUptime }
        scheduleDurationCheck = Self.scheduleOnMain
        makeDriver = { mode in
            if mode == .recording, let direct = BluetoothInputDriver() { return direct }
            return AVEngineCaptureDriver()
        }
    }

    // MARK: - Public API

    /// Pay the process's first audio component and format lookup after onboarding.
    /// The temporary driver is never started. Each press still gets fresh route
    /// and format information, even if the devices change immediately afterwards.
    func warmRecordingFormat() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard current == nil else { return }
        _ = makeDriver(.recording).inputFormat
    }

    func startRecording(
        limitSeconds: TimeInterval? = nil,
        timing: DictationCaptureTiming? = nil,
        stageLog: DictationStageLog? = nil,
        onDurationLimit: (() -> Void)? = nil
    ) throws {
        try start(mode: .recording, limitSeconds: limitSeconds, timing: timing, stageLog: stageLog)
        if let onDurationLimit, let capture = current, let deadline = capture.recordingDeadline {
            enqueueDurationCheck(capture, deadline: deadline, onLimit: onDurationLimit)
        }
    }

    private func enqueueDurationCheck(_ capture: Capture, deadline: TimeInterval, onLimit: @escaping () -> Void) {
        let work = DispatchWorkItem { [weak self, weak capture] in
            guard let self, let capture, self.current === capture else { return }
            capture.durationCheck = nil
            if self.now() < deadline {
                self.enqueueDurationCheck(capture, deadline: deadline, onLimit: onLimit)
            } else {
                onLimit()
            }
        }
        capture.durationCheck = work
        scheduleDurationCheck(max(0, deadline - now()), work)
    }

    /// One immutable snapshot per requested preview, never one queued copy per audio tap.
    func recordingSnapshot() -> [Float] { current?.snapshotSamples() ?? [] }
    var recordingLimitReached: Bool { current?.limitReached ?? false }
    func recordingDurationElapsed(at uptime: TimeInterval) -> Bool {
        guard let deadline = current?.recordingDeadline else { return false }
        return uptime >= deadline
    }
    var hasInterruptedRecording: Bool { current?.hasInterruptedRecording ?? false }

    /// Ends push-to-talk capture. After a device interruption, returns the
    /// accumulated audio when available. An interruption with no audio throws.
    func stopRecording() throws -> [Float] {
        try finishRecording().samples
    }

    func finishRecording(isTap: Bool = false, reason: DictationStageLog.CaptureEndReason? = nil)
        throws -> (samples: [Float], interrupted: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let capture = current, capture.mode == .recording else { return ([], false) }

        capture.durationCheck?.cancel()
        capture.durationCheck = nil
        capture.closeForRelease(isTap: isTap, reason: reason)
        if let failure = capture.latchedFailure {
            let partial = capture.snapshotSamples()
            finishFailure(capture)
            if current === capture { current = nil }
            guard !partial.isEmpty else { throw failure }
            log.info("Recording stopped after interruption: samples=\(partial.count, privacy: .public)")
            try checkSignal(partial)
            return (partial, true)
        }

        cancelDeadline(capture)
        capture.detachInput()?.driver.stop()
        current = nil

        let result = capture.takeSamples()
        let duration = Double(result.count) / 16000.0
        log.info("Recording stopped: \(result.count) samples (\(String(format: "%.1f", duration))s)")
        if !isTap { try checkSignal(result) }
        return (result, false)
    }

    private func checkSignal(_ samples: [Float]) throws {
        // One 16-bit PCM step (-90 dBFS peak). Any louder sample preserves a
        // quiet utterance, even if most of a long recording is digital silence.
        guard samples.count >= 16_000,
              samples.allSatisfy({ abs($0) <= 1.0 / 32_768 }) else { return }
        log.error("Dictation capture unusable: reason=silentInput samples=\(samples.count, privacy: .public)")
        throw AudioCaptureError.silentInput
    }

    /// Silent discard, including a latched failure that was never delivered.
    /// Also the acknowledgement that retires a failed capture the caller will
    /// never stop, so the next start is not rejected as busy.
    func cancelRecording(reason: RecordingCancellationReason) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let capture = current, capture.mode == .recording else { return }
        capture.durationCheck?.cancel()
        capture.durationCheck = nil
        let discardedSamples = capture.markCancelled(reason: reason)
        cancelDeadline(capture)
        capture.detachInput()?.driver.stop()
        current = nil
        log.info("Recording cancelled: reason=\(reason.rawValue, privacy: .public) samples=\(discardedSamples, privacy: .public)")
    }

    // MARK: - Continuous capture (live caption mode)

    /// Live-caption capture path: pushes 16kHz mono Float32 samples to
    /// `onSamples` per buffer. Does not accumulate.
    func startContinuousCapture() throws {
        try start(mode: .continuous)
    }

    /// Silent and idempotent. Suppresses an undelivered failure: the user
    /// asked for the session to end. This is also the acknowledgement that
    /// retires a capture whose failure was already delivered through onError.
    func stopContinuousCapture() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let capture = current, capture.mode == .continuous else { return }
        capture.suppressErrorDelivery()
        cancelDeadline(capture)
        capture.detachInput()?.driver.stop()
        current = nil
        log.info("Continuous capture stopped")
    }

    /// Test seam for the first-buffer deadline body. Production schedules this
    /// same check with capture-identity validation; tests invoke it directly
    /// instead of sleeping for a second.
    func checkFirstBufferDeadline() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let capture = current, let input = capture.input else { return }
        checkFirstBuffer(capture, input: input)
    }

    /// Test-only view of the work item production ALREADY scheduled for the
    /// current capture, so a test can save it, stop, start again and invoke
    /// that exact item. Exposes existing work through the deadline hook; it
    /// adds no clock, scheduler or second injected subsystem.
    func scheduledFirstBufferDeadline() -> DispatchWorkItem? {
        dispatchPrecondition(condition: .onQueue(.main))
        return current?.firstBufferCheck
    }

    // MARK: - Shared start

    private func start(
        mode: Mode,
        limitSeconds: TimeInterval? = nil,
        timing: DictationCaptureTiming? = nil,
        stageLog: DictationStageLog? = nil
    ) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard current == nil else { throw AudioCaptureError.busy }

        let setupStart = ProcessInfo.processInfo.systemUptime
        let capture = Capture(
            mode: mode,
            timing: timing,
            onSamples: onSamples,
            onRMSLevel: onRMSLevel,
            onError: onError,
            stageLog: stageLog,
            limitSeconds: mode == .recording ? limitSeconds : nil,
            now: now
        )
        current = capture

        do {
            let initial = try makeInput(driver: makeDriver(mode))
            let driverStart = ProcessInfo.processInfo.systemUptime
            let input = try startInputWithFallback(initial, capture: capture)
            let driverStarted = ProcessInfo.processInfo.systemUptime
            if let timing {
                log.info("Dictation capture start timing: pressUptimeMs=\(timing.pressUptimeMs, privacy: .public) admissionMs=\(DictationCaptureTiming.milliseconds(from: timing.keyDown, to: timing.admitted), privacy: .public) appSetupMs=\(DictationCaptureTiming.milliseconds(from: timing.admitted, to: setupStart), privacy: .public) audioSetupMs=\(DictationCaptureTiming.milliseconds(from: setupStart, to: driverStart), privacy: .public) driverStartMs=\(DictationCaptureTiming.milliseconds(from: driverStart, to: driverStarted), privacy: .public)")
            }
            log.info("Capture started (native: \(input.nativeFormat.sampleRate)Hz → 16000Hz)")
        } catch {
            capture.suppressErrorDelivery()
            current = nil
            let reason = RecordingCancellationReason(error: error)
            log.error("Capture start failed: reason=\(reason.rawValue, privacy: .public)")
            throw error
        }
    }

    private func makeInput(driver: any CaptureDriver) throws -> CaptureInput {
        let format = driver.inputFormat
        guard format.channelCount > 0, format.sampleRate.isFinite, format.sampleRate > 0 else {
            log.error("Unusable input format: \(format.channelCount) ch, \(format.sampleRate) Hz")
            driver.stop()
            throw AudioCaptureError.invalidInput
        }
        return CaptureInput(driver: driver, nativeFormat: format)
    }

    private func startInputWithFallback(_ input: CaptureInput, capture: Capture) throws -> CaptureInput {
        do {
            try startInput(input, capture: capture)
            return input
        } catch where input.driver is BluetoothInputDriver {
            log.info("Direct Bluetooth input unavailable at start; retrying with AVAudioEngine")
            let fallback = try makeInput(driver: AVEngineCaptureDriver())
            try startInput(fallback, capture: capture)
            return fallback
        }
    }

    private func startInput(_ input: CaptureInput, capture: Capture) throws {
        if capture.mode == .recording {
            let backend = input.driver is BluetoothInputDriver ? "hal" : "avAudioEngine"
            log.info("Dictation capture backend: pressUptimeMs=\(capture.timing?.pressUptimeMs ?? 0, privacy: .public) backend=\(backend, privacy: .public)")
        }
        capture.attach(input)
        do {
            try input.driver.start(
                onBuffer: { [weak self, weak capture, weak input] buffer in
                    guard let self, let capture, let input else { return }
                    self.handleBuffer(buffer, capture: capture, input: input)
                },
                onConfigurationChange: { [weak self, weak capture, weak input] in
                    guard let capture, let input, capture.noteConfigurationChange(on: input) else { return }
                    // AVAudioEngine can deadlock if torn down inside the notification.
                    DispatchQueue.main.async { [weak capture, weak input] in
                        guard let self, let capture, let input, self.current === capture else { return }
                        if capture.mode == .recording, capture.isStartupNotification,
                           input.driver.stillRunningOnOriginalInput(format: input.nativeFormat) {
                            capture.keepStartingInput(input)
                            log.info("Audio configuration changed during startup; retaining running input")
                            return
                        }
                        self.recoverInput(capture, replaced: input)
                    }
                }
            )
        } catch {
            capture.detachInput()?.driver.stop()
            throw AudioCaptureError.startFailed(error)
        }
        scheduleFirstBufferCheck(capture, input: input)
    }

    private func recoverInput(_ capture: Capture, replaced input: CaptureInput) {
        guard let canRetry = capture.beginRecovery(replacing: input) else { return }
        cancelDeadline(capture)
        input.driver.stop()
        log.info("Audio engine configuration changed: samples=\(capture.sampleCount, privacy: .public) retry=\(canRetry, privacy: .public)")
        guard canRetry else {
            failRecovery(capture, cause: .configurationChanged)
            return
        }
        do {
            func reopen() throws -> CaptureInput {
                let input = try makeInput(driver: makeDriver(capture.mode))
                return try startInputWithFallback(input, capture: capture)
            }
            let replacement: CaptureInput
            do {
                replacement = try reopen()
            } catch AudioCaptureError.startFailed(let error)
                where (error as NSError).code == Int(kAudioUnitErr_FormatNotSupported) {
                // The device changed format between tap installation and graph
                // initialization. The rejected graph has already been detached.
                log.info("Recovery input format changed during start; rebuilding the tap once")
                replacement = try reopen()
            }
            log.info("Audio engine reopened: nativeHz=\(replacement.nativeFormat.sampleRate, privacy: .public)")
        } catch {
            failRecovery(capture, cause: RecordingCancellationReason(error: error))
        }
    }

    private func failRecovery(_ capture: Capture, cause: RecordingCancellationReason) {
        guard capture.latchFailure(.configurationChanged) else { return }
        logRecoveryFailure(capture, cause: cause)
        finishFailure(capture)
    }

    private func logRecoveryFailure(_ capture: Capture, cause: RecordingCancellationReason) {
        log.error("Audio engine recovery failed: reason=\(cause.rawValue, privacy: .public) samples=\(capture.sampleCount, privacy: .public)")
    }

    // MARK: - Tap body

    /// Runs on the CoreAudio IO thread. Touches only this capture's immutable
    /// context and its locked record; never the service's mutable callbacks,
    /// AppKit, engine lifecycle or a synchronous main hop.
    private func handleBuffer(_ buffer: AVAudioPCMBuffer, capture: Capture, input: CaptureInput) {
        // Zero-frame callbacks never satisfy first-buffer readiness.
        guard buffer.frameLength > 0, buffer.format == input.nativeFormat else { return }
        guard let samples = capture.acceptBuffer(buffer, from: input, convert: convertedSamples) else { return }
        switch capture.mode {
        case .recording:
            let squares = samples.reduce(Float.zero) { $0 + $1 * $1 }
            capture.onRMSLevel?(sqrt(squares / Float(samples.count)))
        case .continuous:
            capture.onSamples?(samples)
        }
    }

    private func convertedSamples(_ buffer: AVAudioPCMBuffer, input: CaptureInput) -> [Float]? {
        let pcmBuffer: AVAudioPCMBuffer
        if buffer.format != CaptureInput.targetFormat {
            guard let converter = input.converter else { return nil }
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * CaptureInput.targetFormat.sampleRate / input.nativeFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: CaptureInput.targetFormat,
                frameCapacity: frameCapacity
            ) else { return nil }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else {
                log.error("Audio conversion error: \(error?.localizedDescription ?? "unknown", privacy: .private)")
                return nil
            }
            pcmBuffer = convertedBuffer
        } else {
            pcmBuffer = buffer
        }

        guard let channelData = pcmBuffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(pcmBuffer.frameLength)
        guard frameCount > 0 else { return nil }

        return Array(UnsafeBufferPointer(start: channelData, count: frameCount))
    }

    // MARK: - First-buffer deadline

    private func scheduleFirstBufferCheck(_ capture: Capture, input: CaptureInput) {
        let item = DispatchWorkItem { [weak self, weak capture, weak input] in
            guard let self, let capture, let input else { return }
            self.checkFirstBuffer(capture, input: input)
        }
        capture.firstBufferCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func checkFirstBuffer(_ capture: Capture, input: CaptureInput) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard current === capture else { return }
        if capture.needsStartupRecovery(input) {
            recoverInput(capture, replaced: input)
            return
        }
        guard let failure = capture.failIfMissingSamples(from: input) else { return }
        if case .configurationChanged = failure {
            logRecoveryFailure(capture, cause: .noInputBuffer)
        } else {
            log.error("No input buffer within the first-buffer deadline")
        }
        finishFailure(capture)
    }

    private func cancelDeadline(_ capture: Capture) {
        capture.firstBufferCheck?.cancel()
        capture.firstBufferCheck = nil
    }

    // MARK: - Terminal failure

    /// Main-queue cleanup for a latched failure: release the hardware first,
    /// then deliver the callback captured for THIS capture exactly once.
    /// Idempotent, including when `onError` reentrantly calls stop or cancel.
    ///
    /// The failed capture deliberately STAYS in `current`. Releasing the driver
    /// already gave the hardware back, so what remains is a hardware-free
    /// record of the terminal result. It has to outlive this call so that
    /// `stopRecording()` can still throw it; a caller that never stops
    /// acknowledges it through `cancelRecording()` or `stopContinuousCapture()`.
    private func finishFailure(_ capture: Capture) {
        dispatchPrecondition(condition: .onQueue(.main))
        cancelDeadline(capture)
        capture.detachInput()?.driver.stop()
        if let (error, handler) = capture.claimErrorDelivery() {
            handler(error)
        }
    }
}

// MARK: - Capture record

private final class CaptureInput {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    let driver: any CaptureDriver
    let nativeFormat: AVAudioFormat

    // Build the converter when the tap first delivers audio. The capture lock
    // serializes access, and microphone startup can proceed before conversion.
    lazy var converter: AVAudioConverter? = {
        let converter = AVAudioConverter(from: self.nativeFormat, to: CaptureInput.targetFormat)
        if converter == nil { log.error("Could not create input audio converter") }
        return converter
    }()

    init(driver: any CaptureDriver, nativeFormat: AVAudioFormat) {
        self.driver = driver
        self.nativeFormat = nativeFormat
    }
}

private final class Capture {
    let mode: AudioCaptureService.Mode
    let timing: DictationCaptureTiming?
    let onSamples: (([Float]) -> Void)?
    let onRMSLevel: ((Float) -> Void)?
    let onError: ((Error) -> Void)?
    private let stageLog: DictationStageLog?

    // Main-queue only. Datapath and notification callbacks use the locked
    // record below and leave lifecycle operations to the main queue.
    var firstBufferCheck: DispatchWorkItem?

    private let lock = NSLock()
    private var attachedInput: CaptureInput?
    private var configurationPending = false
    private var notifiedBeforeSamples = false
    private var checkingStartupInput = false
    private var awaitingRecoverySamples = false
    private var sawFirstBuffer = false
    private var emittedFirstSamples = false
    private var inputDeliveredSamples = false
    private var accepting = true
    private var failure: AudioCaptureError?
    private var errorDelivered = false
    private var samples: [Float] = []
    private let sampleLimit: Int?
    let recordingDeadline: TimeInterval?
    var durationCheck: DispatchWorkItem?
    private let now: () -> TimeInterval
    private var reachedLimit = false

    init(
        mode: AudioCaptureService.Mode,
        timing: DictationCaptureTiming?,
        onSamples: (([Float]) -> Void)?,
        onRMSLevel: ((Float) -> Void)?,
        onError: ((Error) -> Void)?,
        stageLog: DictationStageLog?,
        limitSeconds: TimeInterval?,
        now: @escaping () -> TimeInterval
    ) {
        self.mode = mode
        self.timing = timing
        self.onSamples = onSamples
        self.onRMSLevel = onRMSLevel
        self.onError = onError
        self.stageLog = stageLog
        self.now = now
        sampleLimit = limitSeconds.map { Int($0 * 16000) }
        recordingDeadline = limitSeconds.map { now() + $0 }
    }

    var input: CaptureInput? { lock.withLock { attachedInput } }
    var limitReached: Bool { lock.withLock { reachedLimit } }
    var latchedFailure: AudioCaptureError? { lock.withLock { failure } }
    var hasInterruptedRecording: Bool { lock.withLock { failure != nil && !samples.isEmpty } }
    var sampleCount: Int { lock.withLock { samples.count } }
    func snapshotSamples() -> [Float] { lock.withLock { samples } }

    func attach(_ input: CaptureInput) {
        lock.withLock {
            attachedInput = input
            configurationPending = false
            inputDeliveredSamples = false
            checkingStartupInput = false
        }
    }

    func detachInput() -> CaptureInput? {
        lock.withLock {
            let detached = attachedInput
            attachedInput = nil
            return detached
        }
    }

    func noteConfigurationChange(on input: CaptureInput) -> Bool {
        lock.withLock {
            guard accepting, attachedInput === input, !configurationPending else { return false }
            notifiedBeforeSamples = !inputDeliveredSamples
            configurationPending = true
            return true
        }
    }

    var isStartupNotification: Bool { lock.withLock { configurationPending && notifiedBeforeSamples } }

    func keepStartingInput(_ input: CaptureInput) {
        lock.withLock {
            guard accepting, attachedInput === input else { return }
            configurationPending = false
            checkingStartupInput = !inputDeliveredSamples
        }
    }

    func needsStartupRecovery(_ input: CaptureInput) -> Bool {
        lock.withLock {
            // The deadline may run after a notification was latched but before
            // its main-queue handler. It must still own a stalled startup.
            guard acceptsAudio(from: input), !inputDeliveredSamples,
                  checkingStartupInput || configurationPending else { return false }
            configurationPending = true
            return true
        }
    }

    /// Allow one replacement per interruption. Its first usable samples
    /// reset the budget. A second change during the restart ends the capture.
    func beginRecovery(replacing input: CaptureInput) -> Bool? {
        lock.withLock {
            guard accepting, attachedInput === input, configurationPending else { return nil }
            attachedInput = nil
            configurationPending = false
            let canRetry = !awaitingRecoverySamples
            awaitingRecoverySamples = true
            return canRetry
        }
    }

    func closeForRelease(isTap: Bool, reason: DictationStageLog.CaptureEndReason?) {
        lock.withLock {
            accepting = false
            if !isTap && (configurationPending || awaitingRecoverySamples) && !reachedLimit {
                failure = .configurationChanged
            }
            if sawFirstBuffer {
                stageLog?.emit(.captureEnded(sampleCount: samples.count, reason: reason))
            }
            #if DEBUG || LAMITYPE_CAPTURE_CI
            dumpOnce(outcome: failure == nil ? "released" : "interrupted")
            #endif
        }
    }

    #if DEBUG || LAMITYPE_CAPTURE_CI
    private var didDump = false

    // Called under the capture lock once admission to the sample buffer closes.
    private func dumpOnce(outcome: String) {
        guard !didDump else { return }
        didDump = true
        CaptureDump.enqueue(samples, pressUptimeMs: timing?.pressUptimeMs, outcome: outcome)
    }
    #endif

    /// Called with the lock held. The wall clock and sample limits span
    /// replacements, including time spent waiting for a new input buffer.
    private func acceptsAudio(from input: CaptureInput) -> Bool {
        guard accepting, attachedInput === input else { return false }
        if let recordingDeadline, now() >= recordingDeadline {
            reachedLimit = true
            accepting = false
            return false
        }
        return true
    }

    func acceptBuffer(
        _ buffer: AVAudioPCMBuffer,
        from input: CaptureInput,
        convert: (AVAudioPCMBuffer, CaptureInput) -> [Float]?
    ) -> [Float]? {
        lock.withLock {
            guard acceptsAudio(from: input) else { return nil }
            if !sawFirstBuffer {
                sawFirstBuffer = true
                if let timing {
                    let arrived = ProcessInfo.processInfo.systemUptime
                    log.info("Dictation first input buffer: pressUptimeMs=\(timing.pressUptimeMs, privacy: .public) keyDownToBufferMs=\(DictationCaptureTiming.milliseconds(from: timing.keyDown, to: arrived), privacy: .public) frames=\(buffer.frameLength, privacy: .public)")
                }
                // Emit under the lock so release cannot log ahead of the first buffer.
                stageLog?.emit(.captureStarted)
            }
            // Finish converting this accepted buffer before a route change or
            // release takes ownership of the sample stream.
            guard let newSamples = convert(buffer, input) else { return nil }
            if !emittedFirstSamples {
                emittedFirstSamples = true
                if let timing {
                    let produced = ProcessInfo.processInfo.systemUptime
                    log.info("Dictation first PCM samples: pressUptimeMs=\(timing.pressUptimeMs, privacy: .public) keyDownToPCMms=\(DictationCaptureTiming.milliseconds(from: timing.keyDown, to: produced), privacy: .public) samples=\(newSamples.count, privacy: .public)")
                }
            }
            inputDeliveredSamples = true
            awaitingRecoverySamples = false
            if mode == .recording {
                if let sampleLimit {
                    samples.append(contentsOf: newSamples.prefix(max(0, sampleLimit - samples.count)))
                    if samples.count >= sampleLimit { accepting = false; reachedLimit = true }
                } else {
                    samples.append(contentsOf: newSamples)
                }
            }
            return newSamples
        }
    }

    func takeSamples() -> [Float] {
        lock.withLock {
            let result = samples
            samples.removeAll(keepingCapacity: false)
            return result
        }
    }

    func latchFailure(_ error: AudioCaptureError) -> Bool {
        lock.withLock {
            guard accepting else { return false }
            accepting = false
            failure = error
            return true
        }
    }

    func failIfMissingSamples(from input: CaptureInput) -> AudioCaptureError? {
        lock.withLock {
            guard acceptsAudio(from: input), !inputDeliveredSamples, !configurationPending else { return nil }
            let error: AudioCaptureError = awaitingRecoverySamples ? .configurationChanged : .noInputBuffer
            accepting = false
            failure = error
            return error
        }
    }

    func markCancelled(reason: RecordingCancellationReason) -> Int {
        lock.withLock {
            accepting = false
            errorDelivered = true
            #if DEBUG || LAMITYPE_CAPTURE_CI
            dumpOnce(outcome: reason.rawValue)
            #endif
            let count = samples.count
            samples.removeAll(keepingCapacity: false)
            return count
        }
    }

    func suppressErrorDelivery() {
        lock.withLock {
            accepting = false
            errorDelivered = true
        }
    }

    func claimErrorDelivery() -> (AudioCaptureError, (Error) -> Void)? {
        lock.withLock {
            guard let failure, !errorDelivered, let onError else { return nil }
            errorDelivered = true
            return (failure, onError)
        }
    }
}
