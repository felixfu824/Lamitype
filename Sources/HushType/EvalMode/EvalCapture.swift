import Carbon
import Foundation

enum SecureInputProbe {
    static func isActive() -> Bool {
        IsSecureEventInputEnabled()
    }
}

@MainActor
enum EvalCapture {
    private(set) static var suppressedCount = 0
    private(set) static var fullCount = 0

    static func record(
        source: EvalSource,
        appBundleID: String?,
        original: String,
        output: String,
        outcome: EvalOutcome,
        reason: String?,
        elapsed: TimeInterval?,
        abandoned: Bool,
        secureInput: Bool? = nil,
        excludedBundleIDs: [String]? = nil,
        store: EvalStore? = nil
    ) {
        let store = store ?? .shared
        let decision = EvalCapturePolicy.decide(
            enabled: AppConfig.shared.evalModeEnabled,
            secureInput: secureInput ?? SecureInputProbe.isActive(),
            targetBundleID: appBundleID,
            excludedBundleIDs: excludedBundleIDs ?? AppConfig.shared.autoPolishExcludedBundleIDs
        )
        guard case .capture = decision, let appBundleID else {
            if case .suppress(let suppression) = decision, suppression != .disabled {
                suppressedCount += 1
                NotificationCenter.default.post(name: .evalStoreDidChange, object: nil)
            }
            return
        }

        let entry = EvalEntry(
            source: source,
            appBundleID: AutoPolishPolicy.normalize(appBundleID),
            original: original,
            output: output,
            outcome: outcome,
            reason: sanitizedReason(reason),
            elapsedMS: elapsed.map { Int(($0 * 1_000).rounded()) },
            abandoned: abandoned
        )
        if !store.append(entry) {
            fullCount += 1
        }
    }

    static func resetSuppressedCount() {
        suppressedCount = 0
        NotificationCenter.default.post(name: .evalStoreDidChange, object: nil)
    }

    private static func sanitizedReason(_ reason: String?) -> String? {
        reason.map { String($0.prefix { $0 != "(" }) }
    }

    #if DEBUG
    static func resetCountersForTesting() {
        suppressedCount = 0
        fullCount = 0
    }
    #endif
}
