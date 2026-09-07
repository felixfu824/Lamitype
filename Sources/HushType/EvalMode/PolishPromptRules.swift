import Foundation

extension PolishPrompt {
    enum PromptSaveError: LocalizedError, Equatable {
        case empty
        case migrationFailed

        var errorDescription: String? {
            switch self {
            case .empty:
                return L10n.string(
                    "eval.prompt.error.empty",
                    fallback: "The prompt cannot be empty. Your previous prompt is still active."
                )
            case .migrationFailed:
                return L10n.string(
                    "eval.prompt.error.migration",
                    fallback: "The prompt files could not be prepared. Your previous prompt is still active."
                )
            }
        }
    }

    static let customPromptFilename = "polish_prompt_custom.txt"
    static let migrationMarkerFilename = ".polish_prompt_migrated_v1"
    static let legacyFullPromptFilename = "polish_prompt.txt"
    static let legacyRulesFilename = "polish_rules.txt"

    static var customPromptURL: URL {
        AppConfig.promptOverrideURL(filename: customPromptFilename)
    }

    static var migrationMarkerURL: URL {
        AppConfig.promptOverrideURL(filename: migrationMarkerFilename)
    }

    static var hasCustomization: Bool {
        _ = migrateLegacyPromptIfNeeded()
        return readFullPrompt(at: customPromptURL) != nil
    }

    /// Returns a value snapshot. Callers retain this String for the lifetime
    /// of a request or batch so later saves cannot alter in-flight work.
    static func effectivePromptSnapshot() -> String {
        if migrateLegacyPromptIfNeeded() {
            return readFullPrompt(at: customPromptURL) ?? systemPrompt
        }
        // A canonical prompt may already exist after an interrupted migration.
        // Keep serving it even while marker/backup repair is retried; writes
        // remain blocked until migration completes.
        if let custom = readFullPrompt(at: customPromptURL) { return custom }
        return legacyEffectivePrompt() ?? systemPrompt
    }

    static func saveCompletePrompt(_ contents: String) throws {
        guard CleanupPromptOverride.parseFullPrompt(contents: contents) != nil else {
            throw PromptSaveError.empty
        }
        guard migrateLegacyPromptIfNeeded() else { throw PromptSaveError.migrationFailed }
        try FileManager.default.createDirectory(
            at: customPromptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: customPromptURL, atomically: true, encoding: .utf8)
        CleanupPromptOverride.invalidate(filename: customPromptFilename)
    }

    static func restoreDefaultPrompt() throws {
        guard migrateLegacyPromptIfNeeded() else { throw PromptSaveError.migrationFailed }
        if FileManager.default.fileExists(atPath: customPromptURL.path) {
            try FileManager.default.removeItem(at: customPromptURL)
        }
        CleanupPromptOverride.invalidate(filename: customPromptFilename)
    }

    /// Idempotent one-time migration. Legacy originals are copied beside the
    /// marker as recoverable backups and are never consulted again afterwards.
    @discardableResult
    static func migrateLegacyPromptIfNeeded() -> Bool {
        let fm = FileManager.default
        guard !migrationIsComplete() else { return true }
        let root = migrationMarkerURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let legacyFullURL = AppConfig.promptOverrideURL(filename: legacyFullPromptFilename)
            let legacyRulesURL = AppConfig.promptOverrideURL(filename: legacyRulesFilename)
            try backupLegacyFileIfPresent(legacyFullURL, fileManager: fm)
            try backupLegacyFileIfPresent(legacyRulesURL, fileManager: fm)
            if readFullPrompt(at: customPromptURL) == nil,
               let migrated = legacyEffectivePrompt() {
                try migrated.write(to: customPromptURL, atomically: true, encoding: .utf8)
            }
            try "migrated\n".write(to: migrationMarkerURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            // Leave the marker absent. A later request retries, while failed
            // writes never replace an already-active custom prompt.
            return false
        }
    }

    private static func legacyEffectivePrompt() -> String? {
        let fullURL = AppConfig.promptOverrideURL(filename: legacyFullPromptFilename)
        if let raw = try? String(contentsOf: fullURL, encoding: .utf8),
           let parsed = CleanupPromptOverride.parse(contents: raw) {
            return parsed
        }
        let rulesURL = AppConfig.promptOverrideURL(filename: legacyRulesFilename)
        if let raw = try? String(contentsOf: rulesURL, encoding: .utf8),
           CleanupPromptOverride.parse(contents: raw) != nil {
            return prompt(withRules: raw)
        }
        return nil
    }

    private static func readFullPrompt(at url: URL) -> String? {
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return CleanupPromptOverride.parseFullPrompt(contents: value)
    }

    private static func migrationIsComplete() -> Bool {
        (try? String(contentsOf: migrationMarkerURL, encoding: .utf8)) == "migrated\n"
    }

    private static func backupLegacyFileIfPresent(_ url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("legacy-backup")
        guard !fileManager.fileExists(atPath: backup.path) else { return }
        try fileManager.copyItem(at: url, to: backup)
    }

    static func prompt(withRules rules: String?) -> String {
        guard let rules, let parsed = CleanupPromptOverride.parse(contents: rules) else {
            return systemPrompt
        }
        let marker = "\nExamples:\n"
        let section = "\nUser preferences (apply in addition to the rules above; ignore any that conflict with them):\n\(parsed)\n"
        if let range = systemPrompt.range(of: marker) {
            return systemPrompt.replacingCharacters(in: range, with: section + marker)
        }
        return systemPrompt + "\n" + section
    }

    static func rerunPrompt(withRules rules: String?) -> String {
        // A non-nil value is an Eval draft snapshot, including an intentionally
        // blank draft. The Eval model blocks blank drafts with a clear reason;
        // never substitute the saved prompt behind the user's back.
        if let rules { return rules }
        return effectivePromptSnapshot()
    }

}
