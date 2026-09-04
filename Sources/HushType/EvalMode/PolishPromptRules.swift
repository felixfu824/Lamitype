import Foundation

extension PolishPrompt {
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

    static var fullOverrideIsActive: Bool {
        CleanupPromptOverride.currentPrompt(filename: "polish_prompt.txt") != nil
    }

    static func rerunPrompt(withRules rules: String?) -> String {
        if let full = CleanupPromptOverride.currentPrompt(filename: "polish_prompt.txt") {
            return full
        }
        return prompt(withRules: rules)
    }

    static func rawRulesContents() -> String {
        rawRulesContents(at: rulesFileURL)
    }

    static func saveRulesVerbatim(_ contents: String) throws {
        try saveRulesVerbatim(contents, at: rulesFileURL)
    }

    static func rawRulesContents(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func saveRulesVerbatim(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
