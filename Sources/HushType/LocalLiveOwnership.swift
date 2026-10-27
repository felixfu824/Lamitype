import Foundation
import MLX

/// Main-actor admission covers caption startup/teardown, not merely isActive.
/// Existing batch/caption coexistence is unchanged when no live lease exists.
@MainActor
enum LocalLiveOwnership {
    static private(set) var liveOwner: UUID?
    static var captionTransitions = 0
    static var localCaptionActive = false
    static var onChange: (() -> Void)?
    private static var priorCacheLimit: Int?

    static func acquire(_ id: UUID) -> Bool {
        guard liveOwner == nil, captionTransitions == 0, !localCaptionActive else { return false }
        liveOwner = id
        priorCacheLimit = MLX.Memory.cacheLimit
        MLX.Memory.cacheLimit = 128 * 1024 * 1024
        NotificationCenter.default.post(name: .localLiveActivityChanged, object: nil)
        onChange?()
        return true
    }

    static func release(_ id: UUID) {
        guard liveOwner == id else { return }
        if let priorCacheLimit { MLX.Memory.cacheLimit = priorCacheLimit }
        priorCacheLimit = nil
        liveOwner = nil
        NotificationCenter.default.post(name: .localLiveActivityChanged, object: nil)
        onChange?()
    }

    static var isBusy: Bool { liveOwner != nil }
    static func beginCaptionTransition() -> Bool {
        guard liveOwner == nil else { return false }
        captionTransitions += 1
        LocalLivePreviewController.availabilityDidChange()
        return true
    }
    static func endCaptionTransition() {
        captionTransitions = max(0, captionTransitions - 1)
        LocalLivePreviewController.availabilityDidChange()
    }
}

/// All experimental model calls execute serially; lease survives task cancellation.
enum LocalLiveInference {
    static let queue = DispatchQueue(label: "com.felix.hushtype.local-live-inference", qos: .userInitiated)
    static func run<T>(_ action: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try action()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

extension Notification.Name {
    static let localLiveActivityChanged = Notification.Name("com.felix.hushtype.localLiveActivityChanged")
}
