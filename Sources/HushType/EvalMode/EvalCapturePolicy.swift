import Foundation

enum EvalCapturePolicy {
    enum Decision: Equatable {
        case capture
        case suppress(Suppression)
    }

    enum Suppression: String, Equatable {
        case disabled
        case secureInput
        case unknownTarget
        case excludedApp
    }

    static func decide(
        enabled: Bool,
        secureInput: Bool,
        targetBundleID: String?,
        excludedBundleIDs: [String]
    ) -> Decision {
        guard enabled else { return .suppress(.disabled) }
        guard !secureInput else { return .suppress(.secureInput) }
        guard let targetBundleID, !AutoPolishPolicy.normalize(targetBundleID).isEmpty else {
            return .suppress(.unknownTarget)
        }
        let target = AutoPolishPolicy.normalize(targetBundleID)
        let excluded = Set(AutoPolishPolicy.normalizedUnique(excludedBundleIDs))
        guard !excluded.contains(target) else { return .suppress(.excludedApp) }
        return .capture
    }
}
