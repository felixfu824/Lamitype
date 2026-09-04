import Foundation

enum EvalReasonText {
    static func string(for token: String?) -> String {
        guard let token else { return "" }
        let keyToken = token.hasPrefix("excludedApp(") ? "excludedApp" : token
        let values: [String: (String, String)] = [
            "disabled": ("eval.reason.disabled", "Auto Polish was off."),
            "unavailable": ("eval.reason.unavailable", "Apple Intelligence was not available."),
            "notLocalEngine": ("eval.reason.not_local_engine", "Cloud dictation is not polished."),
            "unknownTarget": ("eval.reason.unknown_target", "Lamitype could not tell which app was in front."),
            "excludedApp": ("eval.reason.excluded_app", "This app is excluded."),
            "empty": ("eval.reason.empty", "Nothing to polish."),
            "codeDetected": ("eval.reason.code_detected", "Looked like code, so it was left alone."),
            "generationFailed": ("eval.reason.generation_failed", "Apple Intelligence returned an error."),
            "timeout": ("eval.reason.timeout", "Polishing took too long, so the original was kept."),
            "emptyOutput": ("eval.reason.empty_output", "The proofreader returned nothing."),
            "lengthGuard": ("eval.reason.length_guard", "The result changed the length too much."),
            "scriptGuard": ("eval.reason.script_guard", "The result switched writing systems."),
            "mixGuard": ("eval.reason.mix_guard", "The result dropped one of your languages."),
            "refusalGuard": ("eval.reason.refusal_guard", "The proofreader refused instead of proofreading.")
        ]
        guard let value = values[keyToken] else { return token }
        return L10n.string(value.0, fallback: value.1)
    }
}
