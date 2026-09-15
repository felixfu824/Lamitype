import Foundation

/// Abstract source of 16kHz mono Float32 PCM samples.
///
/// `LiveCaptionManager` holds an `any AudioSource` — never a concrete type —
/// so adopters can drop in without reshaping the manager. The protocol is
/// intentionally tiny: start, stop, and two callbacks.
///
/// `start()` is `async throws` because `SystemAudioSource` needs to await
/// `SCShareableContent.current` and `SCStream.startCapture()`. Synchronous
/// adopters (like `MicAudioSource`) implement an immediate-returning `async`
/// function.
protocol AudioSource: AnyObject, Sendable {
    /// Fires per audio buffer on the IO thread that produced it.
    var onSamples: (([Float]) -> Void)? { get set }

    /// Fires when the underlying engine surfaces a mid-session error.
    var onError: ((Error) -> Void)? { get set }

    func start() async throws
    func stop()
}

/// `AudioSource` adapter that wraps an `AudioCaptureService` and forwards
/// `start()` / `stop()` to its continuous-capture methods. The adapter does
/// not own the service — the service is supplied at init time so the host
/// (`AppDelegate`) can decide whether to share an instance with the dictation
/// path or use a fresh one.
///
/// `@unchecked Sendable` is sound only because every property is configured,
/// read and torn down on the main thread: `start()` does its work inside
/// `MainActor.run`, `stop()` asserts the main queue, and the service delivers
/// `onError` on the main queue.
final class MicAudioSource: AudioSource, @unchecked Sendable {
    private let service: AudioCaptureService

    /// Stored locally and copied into the service at `start()`. The service
    /// snapshots its callbacks per capture, so a later mutation can never race
    /// a tap that is already running.
    var onSamples: (([Float]) -> Void)?
    var onError: ((Error) -> Void)?

    /// The one terminal failure this adapter has seen, kept so a failure that
    /// lands before the manager commits to the active state is still visible
    /// to the startup path. Main-thread access.
    private(set) var terminalError: Error?

    init(service: AudioCaptureService) {
        self.service = service
    }

    func start() async throws {
        try await MainActor.run {
            terminalError = nil
            service.onSamples = onSamples
            service.onError = { [weak self] error in
                // Delivered on the main queue by AudioCaptureService.
                guard let self else { return }
                self.terminalError = error
                self.onError?(error)
            }
            do {
                try service.startContinuousCapture()
            } catch {
                // The shared start already cleaned up its own capture; drop the
                // callbacks it would otherwise keep. A thrown startup failure
                // never also arrives through onError.
                service.onSamples = nil
                service.onError = nil
                throw error
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        service.stopContinuousCapture()
        service.onSamples = nil
        service.onError = nil
        onSamples = nil
        onError = nil
    }
}
