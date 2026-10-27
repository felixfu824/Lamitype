import Foundation
import os

private let liveLog = Logger(subsystem: "com.felix.hushtype", category: "local-live")

enum LiveDictationPhase: Equatable { case recording, finalizing, polishing, draining, recovery, finished }

/// One press and its explicit recovery attempts. Main actor owns publication and
/// terminal rights; synchronous inference drains on a serial queue before release.
@MainActor
final class LocalLiveDictationSession {
    let id = UUID()
    private(set) var phase: LiveDictationPhase = .recording
    private(set) var audio: [Float] = []
    private(set) var draft = ""
    private(set) var previewUnavailable = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var blockStart = 0
    private(set) var isBusy = false
    private(set) var cancelled = false
    private(set) var stoppedAtLimit = false
    private var nextTick: TimeInterval = 2
    private var timer: Timer?
    private var startTime: TimeInterval = 0
    private var pressTime: TimeInterval = 0
    private var finalRequested = false
    private var attempt = UUID()
    private var retainedFailure: Error?
    private var firstDraftSeconds: Double?
    private var stoppedTime: Double = 0
    private var peakFootprintMiB: Double = 0
    private var previousSampleTime: Double?
    private var maximumSampleGap: Double = 0
    private(set) var retrying = false
    private var captureErrorPresented = false
    private let capture: AudioCaptureService
    private let now: () -> TimeInterval
    private let recognize: ([Float]) throws -> LiveRecognition
    let isSecure: () -> Bool
    var onUpdate: (() -> Void)?
    var onTap: (() -> Void)?
    var onAutoStop: (() -> Void)?
    var onCaptureError: ((Error) -> Void)?
    var onFailure: ((Error) -> Void)?
    var prepareRecognition: (() async throws -> Void)?
    var formatDraft: (String) -> String = { $0 }
    var prepareFinal: ((String) async -> String?)?
    var onResult: ((String, Bool) -> Void)?
    var onFinished: (() -> Void)?

    init(capture: AudioCaptureService,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         isSecure: @escaping () -> Bool = { SecureInputProbe.isActive() },
         recognize: @escaping ([Float]) throws -> LiveRecognition) {
        self.capture = capture; self.now = now; self.isSecure = isSecure; self.recognize = recognize
    }

    @discardableResult
    func start(automaticTicks: Bool = true, pressUptime: TimeInterval? = nil) throws -> Bool {
        guard !isSecure(), LocalLiveOwnership.acquire(id) else { return false }
        startTime = now()
        pressTime = pressUptime ?? startTime
        capture.onError = { [weak self] error in
            guard let self, self.phase == .recording else { return }
            self.capture.cancelRecording()
            self.reportCaptureError(error)
            self.cancel()
        }
        do { try capture.startRecording(limitSeconds: 60) }
        catch { LocalLiveOwnership.release(id); throw error }
        if automaticTicks {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        return true
    }

    func tick() {
        guard phase != .finished else { return }
        if isSecure() { cancel(); return }
        let sampleTime = now()
        peakFootprintMiB = max(peakFootprintMiB, Double(MemoryUtils.physFootprintMB()))
        if let previousSampleTime { maximumSampleGap = max(maximumSampleGap, sampleTime - previousSampleTime) }
        previousSampleTime = sampleTime
        guard phase == .recording else { return }
        elapsed = max(0, now() - startTime)
        onUpdate?()
        if elapsed >= 60 || capture.recordingLimitReached {
            stoppedAtLimit = true
            onAutoStop?(); stop(); return
        }
        guard elapsed >= nextTick, !isBusy else { return }
        let snapshot = capture.recordingSnapshot()
        let blockEnd = min(snapshot.count, blockStart + 240_000)
        guard blockEnd > blockStart else { return }
        let completedBlock = blockEnd == blockStart + 240_000
        let currentBlock = blockStart
        let slice = Array(snapshot[blockStart..<blockEnd])
        nextTick = (floor(elapsed / 2) + 1) * 2
        isBusy = true
        Task { [self] in
            let result = try? await LocalLiveInference.run {
                let recognition = try self.recognize(slice)
                return self.formatDraft(recognition.text)
            }
            isBusy = false
            if isSecure() { cancel(); return }
            if cancelled { finishCancelled(); return }
            if phase == .recording, blockStart == currentBlock {
                previewUnavailable = result == nil
                if completedBlock { blockStart += 240_000; draft = "" }
                else if let result {
                    draft = result
                    if firstDraftSeconds == nil, !draft.isEmpty { firstDraftSeconds = now() - startTime }
                }
                nextTick = (floor((now() - startTime) / 2) + 1) * 2
                onUpdate?()
            }
            if finalRequested { runFinal() }
        }
    }

    func release() {
        guard phase == .recording else { return }
        let releaseTime = now()
        // A failure latched on the IO thread wins even before onError reaches main.
        let captured: [Float]
        do { captured = try capture.stopRecording() }
        catch { reportCaptureError(error); cancel(); return }
        if releaseTime - pressTime < 0.3 {
            cancelled = true
            finishCancelled()
            onTap?()
        } else { stop(captured: captured, stoppedAt: releaseTime) }
    }

    private func stop(captured: [Float]? = nil, stoppedAt: TimeInterval? = nil) {
        guard phase == .recording else { return }
        let stopTime = stoppedAt ?? now()
        do { if let captured { audio = captured } else { audio = try capture.stopRecording() } }
        catch { reportCaptureError(error); cancel(); return }
        guard audio.count > 4800 else {
            reportCaptureError(AudioCaptureError.insufficientLiveAudio)
            cancel(); return
        }
        stoppedTime = stopTime
        phase = .finalizing; finalRequested = true; onUpdate?()
        if !isBusy { runFinal() }
    }

    private func runFinal() {
        guard finalRequested, !isBusy, !cancelled else { return }
        finalRequested = false; isBusy = true
        let samples = audio, thisAttempt = attempt
        Task { [self] in
            do {
                try await prepareRecognition?()
                guard !cancelled, !isSecure() else { isBusy = false; cancel(); return }
                #if DEBUG
                NativeLocalLiveCounters.finalCalls += 1
                #endif
                let result = try await LocalLiveInference.run { try self.recognize(samples) }
                guard !cancelled, thisAttempt == attempt, !isSecure() else { cancel(); isBusy = false; finishCancelled(); return }
                #if DEBUG
                NativeLocalLiveCounters.lastFinalGeneratedTokens = result.generatedTokens
                NativeLocalLiveCounters.lastFinalEndedByEOS = result.endedByEOS
                if NativeLocalLiveCounters.forceNextFinalIncomplete {
                    NativeLocalLiveCounters.forceNextFinalIncomplete = false
                    throw LiveRecognitionError.incomplete
                }
                #endif
                guard result.isComplete else { throw LiveRecognitionError.incomplete }
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LiveRecognitionError.empty }
                let stopToASRSeconds = now() - stoppedTime
                let finalText = await prepareFinal?(result.text)
                isBusy = false
                guard !cancelled, thisAttempt == attempt, !isSecure(), let finalText else { cancel(); return }
                audio = []; phase = .finished; timer?.invalidate(); timer = nil
                LocalLiveOwnership.release(id)
                peakFootprintMiB = max(peakFootprintMiB, Double(MemoryUtils.physFootprintMB()))
                liveLog.info("final samples=\(samples.count, privacy: .public) tokens=\(result.generatedTokens, privacy: .public) firstDraftSeconds=\(self.firstDraftSeconds ?? -1, privacy: .public) stopToASRSeconds=\(stopToASRSeconds, privacy: .public) stopToPreparedTextSeconds=\(self.now() - self.stoppedTime, privacy: .public) sampledAppPeakMiB=\(self.peakFootprintMiB, privacy: .public) maxSampleGapSeconds=\(self.maximumSampleGap, privacy: .public) retry=\(self.retrying, privacy: .public)")
                onResult?(finalText, retrying)
                onFinished?()
            } catch {
                isBusy = false
                if cancelled || isSecure() { cancel(); return }
                phase = .recovery; retainedFailure = error
                LocalLiveOwnership.release(id)
                onFailure?(error); onUpdate?()
            }
        }
    }

    @discardableResult
    func retry() -> Bool {
        guard phase == .recovery, !isBusy, !audio.isEmpty, !isSecure(), LocalLiveOwnership.acquire(id) else { return false }
        attempt = UUID(); retrying = true; stoppedTime = now(); phase = .finalizing; finalRequested = true
        retainedFailure = nil; onUpdate?(); runFinal(); return true
    }

    func cancel() {
        guard phase != .finished else { return }
        cancelled = true; attempt = UUID(); finalRequested = false
        capture.cancelRecording(); audio = []; draft = ""
        timer?.invalidate(); timer = nil
        if isBusy { phase = .draining; onUpdate?() }
        else { finishCancelled() }
    }

    private func reportCaptureError(_ error: Error) {
        guard !captureErrorPresented else { return }
        captureErrorPresented = true
        onCaptureError?(error)
    }

    private func finishCancelled() {
        guard !isBusy, phase != .finished else { return }
        phase = .finished
        timer?.invalidate(); timer = nil
        LocalLiveOwnership.release(id)
        onFinished?()
    }
}

private extension AudioCaptureError {
    static var insufficientLiveAudio: AudioCaptureError { .startFailed(LiveShortAudioError()) }
}
private struct LiveShortAudioError: LocalizedError {
    var errorDescription: String? { L10n.string("error.audio_capture.too_short", fallback: "Not enough audio was captured. Hold Right Option and try again.") }
}
