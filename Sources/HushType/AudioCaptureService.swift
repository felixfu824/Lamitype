import AVFoundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "audio")

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
    /// The audio device configuration changed under this capture. Terminal.
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
        case .configurationChanged:
            return L10n.string(
                "error.audio_capture.configuration_changed",
                fallback: "The audio device changed. Start again to use the current microphone."
            )
        }
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

    /// Install the tap and the configuration observer, then start the engine.
    /// Any partial setup is torn down before this throws.
    ///
    /// `onConfigurationChange` is invoked synchronously on whatever thread
    /// surfaces the notification, so the caller can latch a failure before any
    /// main-queue cleanup. The driver never performs lifecycle work inside it.
    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onConfigurationChange: @escaping () -> Void
    ) throws

    /// Idempotent. Releases observer, tap and engine.
    func stop()
}

/// Production driver: one fresh `AVAudioEngine` per capture.
///
/// A permanent engine is what broke device switching. Its input node kept
/// returning the format cached from the previous device, so the next tap was
/// installed with a stale format and either threw inside `installTap` or
/// delivered no audio at all. A per-capture engine never carries that state.
final class AVEngineCaptureDriver: CaptureDriver {
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var observerToken: NSObjectProtocol?

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onConfigurationChange: @escaping () -> Void
    ) throws {
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
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            onBuffer(buffer)
        }
        tapInstalled = true

        do {
            try engine.start()
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
/// One `Capture` object per session owns its driver, its snapshot of the
/// service callbacks and its locked state record. Capture identity
/// (`current === capture`) is what keeps a stopped session's late tap,
/// notification or deadline from touching a later one; there are no epochs,
/// generation counters or retry state.
///
/// Lifecycle, the first-buffer deadline and all hardware setup/teardown are
/// main-queue confined.
final class AudioCaptureService {
    enum Mode {
        case recording
        case continuous
    }

    private let makeDriver: () -> any CaptureDriver

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

    init(makeDriver: @escaping () -> any CaptureDriver = { AVEngineCaptureDriver() }) {
        self.makeDriver = makeDriver
    }

    // MARK: - Public API

    func startRecording() throws {
        try start(mode: .recording)
    }

    /// Ends the push-to-talk capture. Throws the latched terminal failure
    /// instead of returning a truncated or empty utterance.
    func stopRecording() throws -> [Float] {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let capture = current, capture.mode == .recording else { return [] }

        capture.closeGate()

        // Checked BEFORE taking samples: a configuration change already
        // discarded them, and a failure latched before release wins over it.
        // Held locally first, because finishFailure may run `onError`, which is
        // allowed to cancel this capture and even start a new one reentrantly.
        if let failure = capture.latchedFailure {
            finishFailure(capture)
            if current === capture { current = nil }
            throw failure
        }

        cancelDeadline(capture)
        capture.releaseDriver()
        current = nil

        let result = capture.takeSamples()
        let duration = Double(result.count) / 16000.0
        log.info("Recording stopped: \(result.count) samples (\(String(format: "%.1f", duration))s)")
        return result
    }

    /// Silent discard, including a latched failure that was never delivered.
    /// Also the acknowledgement that retires a failed capture the caller will
    /// never stop, so the next start is not rejected as busy.
    func cancelRecording() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let capture = current, capture.mode == .recording else { return }
        capture.markCancelled()
        cancelDeadline(capture)
        capture.releaseDriver()
        current = nil
        log.info("Recording cancelled")
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
        capture.closeGate()
        capture.suppressErrorDelivery()
        cancelDeadline(capture)
        capture.releaseDriver()
        current = nil
        log.info("Continuous capture stopped")
    }

    /// Test seam for the first-buffer deadline body. Production schedules this
    /// same check with capture-identity validation; tests invoke it directly
    /// instead of sleeping for a second.
    func checkFirstBufferDeadline() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let capture = current else { return }
        checkFirstBuffer(capture)
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

    private func start(mode: Mode) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard current == nil else { throw AudioCaptureError.busy }

        let driver = makeDriver()
        let nativeFormat = driver.inputFormat
        guard nativeFormat.channelCount > 0,
              nativeFormat.sampleRate.isFinite,
              nativeFormat.sampleRate > 0 else {
            log.error("Unusable input format: \(nativeFormat.channelCount) ch, \(nativeFormat.sampleRate) Hz")
            driver.stop()
            throw AudioCaptureError.invalidInput
        }

        let targetSampleRate: Double = 16000
        let targetChannels: AVAudioChannelCount = 1

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            driver.stop()
            throw NSError(
                domain: "AudioCaptureService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: L10n.string(
                    "error.audio_capture.target_format",
                    fallback: "Failed to create target audio format."
                )]
            )
        }

        let needsConversion = nativeFormat.sampleRate != targetSampleRate
            || nativeFormat.channelCount != targetChannels

        let converter: AVAudioConverter?
        if needsConversion {
            converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
            if converter == nil {
                log.warning("Could not create audio converter, capturing in native format")
            }
        } else {
            converter = nil
        }

        let capture = Capture(
            mode: mode,
            driver: driver,
            nativeFormat: nativeFormat,
            targetFormat: targetFormat,
            converter: converter,
            onSamples: onSamples,
            onRMSLevel: onRMSLevel,
            onError: onError
        )
        current = capture

        do {
            try driver.start(
                onBuffer: { [weak self, weak capture] buffer in
                    guard let self, let capture else { return }
                    self.handleBuffer(buffer, capture: capture)
                },
                onConfigurationChange: { [weak self, weak capture] in
                    guard let capture else { return }
                    // Notification thread: latch only. No engine lifecycle here.
                    // An event that did not win the latch (the gate is closed,
                    // or another failure got there first) schedules nothing.
                    guard capture.latchFailure(.configurationChanged) else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.current === capture else { return }
                        self.finishFailure(capture)
                    }
                }
            )
            // A change that landed during startup is a startup failure: it
            // throws, and never reaches onError.
            if let latched = capture.latchedFailure { throw latched }
            capture.markStarted()
        } catch {
            capture.suppressErrorDelivery()
            capture.closeGate()
            capture.releaseDriver()
            current = nil
            log.error("Capture start failed: \(error.localizedDescription, privacy: .private)")
            throw (error as? AudioCaptureError) ?? .startFailed(error)
        }

        scheduleFirstBufferCheck(capture)
        log.info("Capture started (native: \(nativeFormat.sampleRate)Hz → 16000Hz)")
    }

    // MARK: - Tap body

    /// Runs on the CoreAudio IO thread. Touches only this capture's immutable
    /// context and its locked record; never the service's mutable callbacks,
    /// AppKit, engine lifecycle or a synchronous main hop.
    private func handleBuffer(_ buffer: AVAudioPCMBuffer, capture: Capture) {
        // Zero-frame callbacks never satisfy first-buffer readiness.
        guard buffer.frameLength > 0 else { return }
        guard capture.noteBufferIfAccepting() else { return }

        let pcmBuffer: AVAudioPCMBuffer
        if let converter = capture.converter {
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * capture.targetFormat.sampleRate / capture.nativeFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: capture.targetFormat,
                frameCapacity: frameCapacity
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else {
                log.error("Audio conversion error: \(error?.localizedDescription ?? "unknown", privacy: .private)")
                return
            }
            pcmBuffer = convertedBuffer
        } else {
            pcmBuffer = buffer
        }

        guard let channelData = pcmBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(pcmBuffer.frameLength)
        guard frameCount > 0 else { return }

        let newSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        switch capture.mode {
        case .recording:
            var rms: Float = 0
            for i in 0..<frameCount {
                rms += channelData[i] * channelData[i]
            }
            rms = sqrt(rms / max(Float(frameCount), 1))
            // Gate rechecked under the lock; callback invoked outside it.
            guard capture.appendIfAccepting(newSamples) else { return }
            capture.onRMSLevel?(rms)
        case .continuous:
            guard capture.isAccepting else { return }
            capture.onSamples?(newSamples)
        }
    }

    // MARK: - First-buffer deadline

    private func scheduleFirstBufferCheck(_ capture: Capture) {
        let item = DispatchWorkItem { [weak self, weak capture] in
            guard let self, let capture else { return }
            self.checkFirstBuffer(capture)
        }
        capture.firstBufferCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    /// One scheduled check, never rescheduled and never cancelled from the tap.
    /// It cheaply no-ops once a buffer has arrived.
    private func checkFirstBuffer(_ capture: Capture) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard current === capture else { return }
        guard capture.needsNoInputBufferFailure() else { return }
        guard capture.latchFailure(.noInputBuffer) else { return }
        log.error("No input buffer within the first-buffer deadline")
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
        capture.releaseDriver()
        if let (error, handler) = capture.claimErrorDelivery() {
            handler(error)
        }
    }
}

// MARK: - Capture

/// One capture session. A lifetime and ownership container, not an epoch:
/// identity alone decides whether a late callback still applies.
private final class Capture {
    let mode: AudioCaptureService.Mode
    let nativeFormat: AVAudioFormat
    let targetFormat: AVAudioFormat
    let converter: AVAudioConverter?

    // Snapshotted at start so the tap can never read a service property that
    // a later start or stop has since replaced.
    let onSamples: (([Float]) -> Void)?
    let onRMSLevel: ((Float) -> Void)?
    let onError: ((Error) -> Void)?

    /// Main-queue only. Held until main-queue cleanup runs so the engine is
    /// never released on a notification or IO thread.
    private var driver: (any CaptureDriver)?

    /// Main-queue only.
    var firstBufferCheck: DispatchWorkItem?

    private let lock = NSLock()
    private var accepting = true
    private var started = false
    private var sawBuffer = false
    private var failure: AudioCaptureError?
    private var cancelled = false
    private var errorDelivered = false
    private var samples: [Float] = []

    init(
        mode: AudioCaptureService.Mode,
        driver: any CaptureDriver,
        nativeFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter?,
        onSamples: (([Float]) -> Void)?,
        onRMSLevel: ((Float) -> Void)?,
        onError: ((Error) -> Void)?
    ) {
        self.mode = mode
        self.driver = driver
        self.nativeFormat = nativeFormat
        self.targetFormat = targetFormat
        self.converter = converter
        self.onSamples = onSamples
        self.onRMSLevel = onRMSLevel
        self.onError = onError
    }

    // MARK: Hardware ownership (main queue)

    func releaseDriver() {
        driver?.stop()
        driver = nil
    }

    // MARK: Locked record

    var isAccepting: Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting
    }

    func markStarted() {
        lock.lock(); defer { lock.unlock() }
        started = true
    }

    func closeGate() {
        lock.lock(); defer { lock.unlock() }
        accepting = false
    }

    /// Marks readiness before conversion and reports whether this capture is
    /// still accepting audio.
    func noteBufferIfAccepting() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return false }
        sawBuffer = true
        return true
    }

    func appendIfAccepting(_ newSamples: [Float]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return false }
        samples.append(contentsOf: newSamples)
        return true
    }

    func takeSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let result = samples
        samples.removeAll(keepingCapacity: false)
        return result
    }

    /// First failure wins. Closes the gate immediately and drops any audio
    /// accumulated before the failure. Returns true for the first caller.
    ///
    /// A notification that reaches an already-closed gate loses: a normal stop
    /// or a cancel has taken ownership of this capture, and an event still in
    /// flight when that happened must never erase the audio the caller is
    /// about to take, nor invent a failure after a clean result.
    func latchFailure(_ error: AudioCaptureError) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting, !cancelled, failure == nil else { return false }
        accepting = false
        samples.removeAll(keepingCapacity: false)
        failure = error
        return true
    }

    var latchedFailure: AudioCaptureError? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    func needsNoInputBufferFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return started && accepting && !sawBuffer && failure == nil
    }

    func markCancelled() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        accepting = false
        errorDelivered = true
        samples.removeAll(keepingCapacity: false)
    }

    func suppressErrorDelivery() {
        lock.lock(); defer { lock.unlock() }
        accepting = false
        errorDelivered = true
    }

    /// Claims the one-shot delivery right. `errorDelivered` is set under the
    /// lock before the handler is returned, so a reentrant stop or cancel
    /// inside `onError` cannot produce a second callback.
    func claimErrorDelivery() -> (AudioCaptureError, (Error) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        guard let failure, !errorDelivered, !cancelled else { return nil }
        errorDelivered = true
        guard let onError else { return nil }
        return (failure, onError)
    }
}
