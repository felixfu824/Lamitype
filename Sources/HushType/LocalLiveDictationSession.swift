import Foundation
import os

private let liveLog = Logger(subsystem: "com.felix.hushtype", category: "local-live")

enum LiveDictationPhase: Equatable { case recording, finalizing, polishing, draining, recovery, finished }

/// One press and its explicit recovery attempts. Main actor owns publication and
/// terminal rights; synchronous inference drains on a serial queue before release.
@MainActor
final class LocalLiveDictationSession {
    let stageLog = DictationStageLog()
    var id: UUID { stageLog.pressID }
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
    private(set) var clearedFinalForSecureInput = false
    private(set) var copyOnlyReason: LivePasteReason?
    private var finalCharCount = 0
    private var didLogFinalSkip = false
    private var captureErrorPresented = false
    private let capture: AudioCaptureService
    private let now: () -> TimeInterval
    private let acquireOwnership: @MainActor (UUID) -> Bool
    private let releaseOwnership: @MainActor (UUID) -> Void
    private let recognize: ([Float]) throws -> LiveRecognition
    let isSecure: () -> Bool
    var onUpdate: (() -> Void)?
    var onTap: (() -> Void)?
    var onAutoStop: (() -> Void)?
    var onCaptureError: ((Error) -> Void)?
    var onCaptureInterrupted: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var prepareRecognition: (() async throws -> Void)?
    var formatDraft: (String) -> String = { $0 }
    var prepareFinal: ((String) async -> String?)?
    var onResult: ((String, Bool) -> Void)?
    var onFinished: (() -> Void)?

    init(capture: AudioCaptureService,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         isSecure: @escaping () -> Bool = { SecureInputProbe.isActive() },
         acquireOwnership: @escaping @MainActor (UUID) -> Bool = { LocalLiveOwnership.acquire($0) },
         releaseOwnership: @escaping @MainActor (UUID) -> Void = { LocalLiveOwnership.release($0) },
         recognize: @escaping ([Float]) throws -> LiveRecognition) {
        self.capture = capture; self.now = now; self.isSecure = isSecure; self.recognize = recognize
        self.acquireOwnership = acquireOwnership; self.releaseOwnership = releaseOwnership
    }

    @discardableResult
    func start(automaticTicks: Bool = true, pressUptime: TimeInterval? = nil,
               captureTiming: DictationCaptureTiming? = nil) throws -> Bool {
        guard !isSecure(), acquireOwnership(id) else { return false }
        stageLog.emit(.pressAdmitted)
        startTime = now()
        pressTime = pressUptime ?? startTime
        capture.onError = { [weak self] error in
            guard let self, self.phase == .recording else { return }
            if self.capture.hasInterruptedRecording {
                self.onCaptureInterrupted?()
                return
            }
            self.reportCaptureError(error)
            self.cancel(reason: RecordingCancellationReason(error: error))
        }
        do { try capture.startRecording(limitSeconds: 60, timing: captureTiming, stageLog: stageLog) }
        catch { releaseOwnership(id); throw error }
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
        if isSecure() { cancel(reason: .secureInput); return }
        let sampleTime = now()
        peakFootprintMiB = max(peakFootprintMiB, Double(MemoryUtils.physFootprintMB()))
        if let previousSampleTime { maximumSampleGap = max(maximumSampleGap, sampleTime - previousSampleTime) }
        previousSampleTime = sampleTime
        guard phase == .recording else { return }
        elapsed = max(0, now() - startTime)
        if !capture.hasInterruptedRecording { onUpdate?() }
        if elapsed >= 60 || capture.recordingLimitReached {
            stoppedAtLimit = true
            onAutoStop?(); stop(); return
        }
        guard !capture.hasInterruptedRecording else { return }
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
            if isSecure() { cancel(reason: .secureInput); return }
            if cancelled { finishCancelled(); return }
            if phase == .recording, !capture.hasInterruptedRecording, blockStart == currentBlock {
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
        let isTap = isTranslationTap(elapsed: releaseTime - pressTime, captureFailed: false)
        let recording: (samples: [Float], interrupted: Bool)
        do { recording = try capture.finishRecording(isTap: isTap) }
        catch { reportCaptureError(error); cancel(reason: RecordingCancellationReason(error: error)); return }
        if isTap {
            cancelled = true
            finishCancelled()
            onTap?()
        } else { stop(recording: recording, stoppedAt: releaseTime) }
    }

    private func stop(recording: (samples: [Float], interrupted: Bool)? = nil, stoppedAt: TimeInterval? = nil) {
        guard phase == .recording else { return }
        let stopTime = stoppedAt ?? now()
        let finished: (samples: [Float], interrupted: Bool)
        do { finished = try recording ?? capture.finishRecording() }
        catch { reportCaptureError(error); cancel(reason: RecordingCancellationReason(error: error)); return }
        audio = finished.samples
        guard finished.interrupted || audio.count > 4800 else {
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
        didLogFinalSkip = false
        finalCharCount = 0
        let samples = audio, thisAttempt = attempt
        Task { [self] in
            do {
                try await prepareRecognition?()
                guard !abortFinalIfNeeded(attempt: thisAttempt) else { return }
                #if DEBUG
                NativeLocalLiveCounters.finalCalls += 1
                #endif
                let recognitionStarted = now()
                let result = try await LocalLiveInference.run { try self.recognize(samples) }
                let recognitionLatency = now() - recognitionStarted
                guard !abortFinalIfNeeded(attempt: thisAttempt) else { return }
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
                finalCharCount = result.text.count
                stageLog.emit(.transcriptionDone(text: result.text, latency: recognitionLatency))
                let stopToASRSeconds = now() - stoppedTime
                let prepared = await prepareFinal?(result.text)
                guard !abortFinalIfNeeded(attempt: thisAttempt) else { return }
                isBusy = false
                let finalText: String
                if let prepared, !prepared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalText = prepared
                } else {
                    // ASR completed. Preserve its output for explicit Copy when
                    // preparation could not produce a deliverable result.
                    finalText = result.text
                    copyOnlyReason = .preparationUnavailable
                }
                audio = []; phase = .finished; timer?.invalidate(); timer = nil
                releaseOwnership(id)
                peakFootprintMiB = max(peakFootprintMiB, Double(MemoryUtils.physFootprintMB()))
                liveLog.info("final samples=\(samples.count, privacy: .public) tokens=\(result.generatedTokens, privacy: .public) firstDraftSeconds=\(self.firstDraftSeconds ?? -1, privacy: .public) stopToASRSeconds=\(stopToASRSeconds, privacy: .public) stopToPreparedTextSeconds=\(self.now() - self.stoppedTime, privacy: .public) sampledAppPeakMiB=\(self.peakFootprintMiB, privacy: .public) maxSampleGapSeconds=\(self.maximumSampleGap, privacy: .public) retry=\(self.retrying, privacy: .public)")
                if let onResult { onResult(finalText, retrying) }
                else { logFinalSkip(.missingRecipient) }
                onFinished?()
            } catch {
                isBusy = false
                guard !abortFinalIfNeeded(attempt: thisAttempt) else { return }
                logFinalSkip(.recognitionFailed)
                phase = .recovery; retainedFailure = error
                releaseOwnership(id)
                onFailure?(error); onUpdate?()
            }
        }
    }

    var canPrepareFinal: Bool {
        guard !isSecure() else {
            cancel(reason: .secureInput)
            return false
        }
        return !cancelled
    }

    private func logFinalSkip(_ reason: LivePasteReason) {
        guard !didLogFinalSkip else { return }
        didLogFinalSkip = true
        stageLog.emit(.livePasteSkipped(reason, charCount: finalCharCount, copyAvailable: false))
    }

    private func abortFinalIfNeeded(attempt expected: UUID) -> Bool {
        let secure = isSecure()
        guard cancelled || attempt != expected || secure else { return false }
        isBusy = false
        if !secure, !cancelled { logFinalSkip(.superseded) }
        cancel(reason: secure ? .secureInput : .userDiscarded)
        return true
    }

    @discardableResult
    func retry() -> Bool {
        guard phase == .recovery, !isBusy, !audio.isEmpty, !isSecure(), acquireOwnership(id) else { return false }
        attempt = UUID(); retrying = true; stoppedTime = now(); phase = .finalizing; finalRequested = true
        retainedFailure = nil; onUpdate?(); runFinal(); return true
    }

    func cancel(reason: RecordingCancellationReason = .userDiscarded) {
        guard phase != .finished else { return }
        if phase == .finalizing || phase == .polishing {
            if reason == .secureInput { clearedFinalForSecureInput = true }
            logFinalSkip(reason == .secureInput ? .secureInput : .cancelled)
        }
        cancelled = true; attempt = UUID(); finalRequested = false
        capture.cancelRecording(reason: reason); audio = []; draft = ""
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
        releaseOwnership(id)
        onFinished?()
    }
}

private extension AudioCaptureError {
    static var insufficientLiveAudio: AudioCaptureError { .startFailed(LiveShortAudioError()) }
}
private struct LiveShortAudioError: LocalizedError {
    var errorDescription: String? { ShortcutDisplay.format(
                "error.audio_capture.too_short",
                "Not enough audio was captured. Hold %1$@ and try again.", spoken: true
            ) }
}
