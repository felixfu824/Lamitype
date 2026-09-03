import Foundation

enum AutoPolishPolicy {
    enum Decision: Equatable {
        case polish
        case skip(Reason)
    }

    enum Reason: Equatable {
        case disabled
        case unavailable
        case notLocalEngine
        case unknownTarget
        case excludedApp(String)

        var stableToken: String {
            switch self {
            case .disabled: return "disabled"
            case .unavailable: return "unavailable"
            case .notLocalEngine: return "notLocalEngine"
            case .unknownTarget: return "unknownTarget"
            case .excludedApp(let bundleID): return "excludedApp(\(bundleID))"
            }
        }
    }

    static func decide(
        enabled: Bool,
        available: Bool,
        engine: AppConfig.DictationEngine,
        targetBundleID: String?,
        excludedBundleIDs: [String]
    ) -> Decision {
        guard enabled else { return .skip(.disabled) }
        guard engine == .local else { return .skip(.notLocalEngine) }
        guard available else { return .skip(.unavailable) }
        guard let targetBundleID, !normalize(targetBundleID).isEmpty else {
            return .skip(.unknownTarget)
        }

        let normalizedTarget = normalize(targetBundleID)
        let exclusions = Set(normalizedUnique(excludedBundleIDs))
        guard !exclusions.contains(normalizedTarget) else {
            return .skip(.excludedApp(normalizedTarget))
        }
        return .polish
    }

    static func decideNow(
        engine: AppConfig.DictationEngine,
        targetBundleID: String?
    ) -> Decision {
        decide(
            enabled: AppConfig.shared.autoPolishDictationEnabled,
            available: TextPolisher.isAvailableCached,
            engine: engine,
            targetBundleID: targetBundleID,
            excludedBundleIDs: AppConfig.shared.autoPolishExcludedBundleIDs
        )
    }

    static func normalize(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedUnique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { id in
            let normalized = normalize(id)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}
