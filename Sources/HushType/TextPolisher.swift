import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "text-polisher")

enum PolishResult: Sendable {
    case success(polished: String, changed: Bool)
    case failure(PolishError)
}

enum PolishError: LocalizedError, Sendable {
    case disabled
    case unavailable(String)
    case emptySelection
    case codeDetected
    case generationFailed(String)
    case timeout(String)
    case emptyOutput
    case lengthGuard
    case scriptGuard
    case mixGuard
    case refusalGuard

    var errorDescription: String? {
        switch self {
        case .disabled:
            return L10n.string("error.polish.disabled", fallback: "Text Polish is turned off.")
        case .unavailable(let reason):
            return L10n.format(
                "error.polish.unavailable",
                "Text Polish requires macOS 26 + Apple Intelligence.\n\n%1$@",
                arguments: [reason]
            )
        case .emptySelection:
            return L10n.string("error.selection.none", fallback: "No text was selected.")
        case .codeDetected:
            return L10n.string(
                "error.polish.code_detected",
                fallback: "Selection looks like code; not polished."
            )
        case .generationFailed(let reason):
            return reason
        case .timeout(let reason):
            return reason
        case .emptyOutput:
            return L10n.string(
                "error.polish.empty_output",
                fallback: "Apple Intelligence returned an empty result."
            )
        case .lengthGuard:
            return L10n.string(
                "error.polish.length_guard",
                fallback: "The result changed the selection length too much. The original text was left untouched."
            )
        case .scriptGuard:
            return L10n.string(
                "error.polish.script_guard",
                fallback: "The result changed the selection's dominant writing system. The original text was left untouched."
            )
        case .mixGuard:
            return L10n.string(
                "error.polish.mix_guard",
                fallback: "The result dropped one of the selection's languages. The original text was left untouched."
            )
        case .refusalGuard:
            return L10n.string(
                "error.polish.refusal_guard",
                fallback: "Apple Intelligence returned a refusal instead of proofreading the selection."
            )
        }
    }

    /// Guards that indicate the model changed the selection's language rather
    /// than proofreading it - the failures worth a mix-reminder retry.
    var isLanguageGuard: Bool {
        switch self {
        case .scriptGuard, .mixGuard: return true
        default: return false
        }
    }

    var stableToken: String {
        switch self {
        case .disabled: return "disabled"
        case .unavailable: return "unavailable"
        case .emptySelection: return "empty"
        case .codeDetected: return "codeDetected"
        case .generationFailed: return "generationFailed"
        case .timeout: return "timeout"
        case .emptyOutput: return "emptyOutput"
        case .lengthGuard: return "lengthGuard"
        case .scriptGuard: return "scriptGuard"
        case .mixGuard: return "mixGuard"
        case .refusalGuard: return "refusalGuard"
        }
    }
}

private final class CallerReturnRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var resolved = false
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func retain(_ tasks: [Task<Void, Never>]) {
        let shouldCancel: Bool
        lock.lock()
        if resolved {
            shouldCancel = true
        } else {
            self.tasks = tasks
            shouldCancel = false
        }
        lock.unlock()
        if shouldCancel {
            tasks.forEach { $0.cancel() }
        }
    }

    func resolve(_ value: Value?) {
        let continuation: CheckedContinuation<Value?, Never>?
        lock.lock()
        if resolved {
            continuation = nil
        } else {
            resolved = true
            continuation = self.continuation
            self.continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func cancelLosers() {
        lock.lock()
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }
}

enum TextPolisher {
    static let dictationDeadlineSeconds: UInt64 = 8

    enum RerunBudget: UInt64, Sendable {
        case dictation = 8
        case polish = 30
    }
    enum ValidationResult {
        case ok
        case unavailable(reason: String)
    }

    /// Tap handling reads this stored value only. It is refreshed at launch,
    /// app activation, and after toggle validation; never on a key event.
    private(set) static var isAvailableCached = false
    private(set) static var unavailableReasonCached = L10n.string(
        "error.polish.apple_unavailable",
        fallback: "Apple Intelligence is unavailable."
    )

    @MainActor
    static func refreshAvailabilityCache() {
        guard #available(macOS 26.0, *) else {
            isAvailableCached = false
            unavailableReasonCached = L10n.string(
                "error.polish.macos_too_old",
                fallback: "This Mac is running an earlier version of macOS."
            )
            return
        }

        if let reason = FoundationModelsPolisher.availabilityReason() {
            isAvailableCached = false
            unavailableReasonCached = reason
        } else {
            isAvailableCached = true
            unavailableReasonCached = ""
        }
        log.info("Availability cache refreshed: \(self.isAvailableCached, privacy: .public)")
    }

    @MainActor
    static func validate() async -> ValidationResult {
        guard #available(macOS 26.0, *) else {
            refreshAvailabilityCache()
            return .unavailable(reason: unavailableReasonCached)
        }

        let result = await FoundationModelsPolisher.validate()
        switch result {
        case .ok:
            isAvailableCached = true
            unavailableReasonCached = ""
            return .ok
        case .unavailable(let reason):
            isAvailableCached = false
            unavailableReasonCached = reason
            return .unavailable(reason: reason)
        }
    }

    static func polish(_ text: String) async -> PolishResult {
        await polish(
            text,
            requiresManualToggle: true,
            usesCallerReturnDeadline: false,
            deadlineSeconds: 30,
            startedAt: Date(),
            instructions: nil
        )
    }

    static func polishDictation(_ text: String) async -> PolishResult {
        await polish(
            text,
            requiresManualToggle: false,
            usesCallerReturnDeadline: true,
            deadlineSeconds: dictationDeadlineSeconds,
            startedAt: Date(),
            instructions: nil
        )
    }

    static func rerun(
        _ text: String,
        instructions: String?,
        budget: RerunBudget
    ) async -> PolishResult {
        let prompt = PolishPrompt.rerunPrompt(withRules: instructions)
        return await polish(
            text,
            requiresManualToggle: false,
            usesCallerReturnDeadline: true,
            deadlineSeconds: budget.rawValue,
            startedAt: Date(),
            instructions: prompt
        )
    }

    private static func polish(
        _ text: String,
        requiresManualToggle: Bool,
        usesCallerReturnDeadline: Bool,
        deadlineSeconds: UInt64,
        startedAt: Date,
        instructions: String?
    ) async -> PolishResult {
        if requiresManualToggle, !AppConfig.shared.textPolishEnabled {
            return .failure(.disabled)
        }
        let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return .failure(.emptySelection) }
        guard !looksLikeCode(text) else { return .failure(.codeDetected) }
        guard isAvailableCached else {
            return .failure(.unavailable(unavailableReasonCached))
        }
        guard #available(macOS 26.0, *) else {
            return .failure(.unavailable(L10n.string(
                "error.polish.macos_too_old",
                fallback: "This Mac is running an earlier version of macOS."
            )))
        }

        let modelResult = await modelAttempt(
            text,
            mixRetry: false,
            usesCallerReturnDeadline: usesCallerReturnDeadline,
            deadlineSeconds: deadlineSeconds,
            startedAt: startedAt,
            instructions: instructions
        )
        guard let modelResult else {
            return .failure(timeoutError(forManualPolish: !usesCallerReturnDeadline))
        }

        switch modelResult {
        case .failure(let error):
            return .failure(.generationFailed(error.localizedDescription))
        case .success(let polished):
            let validated = validateOutput(polished, input: text)
            if case .failure(let guardError) = validated,
               guardError.isLanguageGuard {
                if usesCallerReturnDeadline,
                   remainingBudget(deadlineSeconds: deadlineSeconds, startedAt: startedAt) < 1 {
                    return validated
                }
                let retryResult = await modelAttempt(
                    text,
                    mixRetry: true,
                    usesCallerReturnDeadline: usesCallerReturnDeadline,
                    deadlineSeconds: deadlineSeconds,
                    startedAt: startedAt,
                    instructions: instructions
                )
                guard let retryResult else {
                    return !usesCallerReturnDeadline
                        ? validated
                        : .failure(timeoutError(forManualPolish: false))
                }
                if case .success(let retried) = retryResult,
                   case .success(let polished, let changed) = validateOutput(retried, input: text) {
                    return .success(polished: polished, changed: changed)
                }
            }
            return validated
        }
    }

    private static func modelAttempt(
        _ text: String,
        mixRetry: Bool,
        usesCallerReturnDeadline: Bool,
        deadlineSeconds: UInt64,
        startedAt: Date,
        instructions: String?
    ) async -> Result<String, Error>? {
        let work: @Sendable () async -> Result<String, Error> = {
            if #available(macOS 26.0, *) {
                return await FoundationModelsPolisher.polish(
                    text,
                    mixRetry: mixRetry,
                    instructions: instructions
                )
            }
            return .failure(PolishError.unavailable(L10n.string(
                "error.polish.macos_too_old",
                fallback: "This Mac is running an earlier version of macOS."
            )))
        }
        if !usesCallerReturnDeadline {
            // The established manual path intentionally gets a fresh 30-second
            // deadline for each attempt.
            return await withDeadline(seconds: deadlineSeconds, work)
        }
        let remaining = remainingBudget(deadlineSeconds: deadlineSeconds, startedAt: startedAt)
        guard remaining > 0 else { return nil }
        return await withCallerReturnDeadline(seconds: remaining, work)
    }

    private static func remainingBudget(deadlineSeconds: UInt64, startedAt: Date) -> TimeInterval {
        max(0, TimeInterval(deadlineSeconds) - Date().timeIntervalSince(startedAt))
    }

    private static func timeoutError(forManualPolish: Bool) -> PolishError {
        if forManualPolish {
            return .generationFailed(L10n.string(
                "error.polish.timeout",
                fallback: "Apple Intelligence timed out after 30 seconds."
            ))
        }
        return .timeout(L10n.string(
            "error.polish.timeout_dictation",
            fallback: "Apple Intelligence timed out after 8 seconds."
        ))
    }

    /// Returns at the deadline even if the underlying Foundation Models call
    /// ignores cancellation. A timed-out respond may continue in the abandoned
    /// task, but its result is discarded and it has no insertion side effects.
    static func withCallerReturnDeadline<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        guard seconds > 0 else { return nil }
        let race = CallerReturnRace<T>()
        let result = await withCheckedContinuation { continuation in
            race.install(continuation)
            let workTask = Task {
                race.resolve(await work())
            }
            let sleeperTask = Task {
                let nanoseconds = UInt64(seconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                race.resolve(nil)
            }
            race.retain([workTask, sleeperTask])
        }
        race.cancelLosers()
        return result
    }

    private static func withDeadline<T: Sendable>(
        seconds: UInt64,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func validateOutput(_ output: String, input: String) -> PolishResult {
        // If the model's only edit was a 妳 swap, this restores the input
        // exactly and the polish correctly reports "no changes needed".
        let output = PolishDiff.revertingNiSwaps(original: input, polished: output)
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return .failure(.emptyOutput) }

        let inputLength = trimmedInput.count
        let outputLength = trimmedOutput.count
        if inputLength >= 20 {
            let ratio = Double(outputLength) / Double(inputLength)
            guard (0.5...2.0).contains(ratio) else { return .failure(.lengthGuard) }
        } else {
            guard abs(outputLength - inputLength) <= 10 else { return .failure(.lengthGuard) }
        }

        guard dominantScriptBucket(trimmedInput) == dominantScriptBucket(trimmedOutput) else {
            return .failure(.scriptGuard)
        }
        // Translation of a mixed-language selection can pass the
        // dominant-bucket check when the minority script is small, and
        // partial translations keep a token of each language, so require
        // proportional retention: each script keeps ≥60% of its characters.
        // Legitimate proofreads sit near 100%; translations fall far below.
        let inputHan = hanCount(trimmedInput)
        let inputLatin = latinLetterCount(trimmedInput)
        if inputHan >= 2 && inputLatin >= 2 {
            let hanRetention = Double(hanCount(trimmedOutput)) / Double(inputHan)
            let latinRetention = Double(latinLetterCount(trimmedOutput)) / Double(inputLatin)
            guard hanRetention >= 0.6 && latinRetention >= 0.6 else {
                return .failure(.mixGuard)
            }
        }
        guard !isNovelRefusal(output: trimmedOutput, input: trimmedInput) else {
            return .failure(.refusalGuard)
        }

        // Return the trimmed text so what gets pasted matches what `changed`
        // compared - FM occasionally pads leading/trailing whitespace.
        return .success(polished: trimmedOutput, changed: trimmedOutput != trimmedInput)
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        if text.contains("```") || text.contains("~~~") { return true }

        let tokenPattern = #"\b(?:[a-z]+[A-Z][A-Za-z0-9]*|[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+)\b"#
        if let regex = try? NSRegularExpression(pattern: tokenPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.numberOfMatches(in: text, range: range) >= 3 { return true }
        }

        // Bare parentheses/angle brackets appear constantly in ordinary prose
        // ("use (A) then (B)"), so density alone false-positives; require at
        // least one statement-shaped symbol before the density test can trip.
        let statementSymbols = text.filter { "{};".contains($0) }.count
        let symbols = text.filter { "{};()=><".contains($0) }.count
        return statementSymbols >= 1 && symbols >= 4
            && Double(symbols) / Double(max(text.count, 1)) >= 0.12
    }

    private static func hanCount(_ text: String) -> Int {
        text.unicodeScalars.lazy.filter { ScriptDetector.isHan($0.value) }.count
    }

    private static func latinLetterCount(_ text: String) -> Int {
        text.unicodeScalars.lazy.filter {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
        }.count
    }

    private enum ScriptBucket: CaseIterable {
        case han
        case kana
        case hangul
        case other
    }

    private static func dominantScriptBucket(_ text: String) -> ScriptBucket {
        var counts = Dictionary(uniqueKeysWithValues: ScriptBucket.allCases.map { ($0, 0) })
        for scalar in text.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            let value = scalar.value
            let bucket: ScriptBucket
            if ScriptDetector.isHan(value) {
                bucket = .han
            } else if (0x3040...0x30FA).contains(value)
                        || (0x30FC...0x30FF).contains(value)
                        || (0xFF66...0xFF9F).contains(value) {
                bucket = .kana
            } else if (0xAC00...0xD7A3).contains(value) {
                bucket = .hangul
            } else {
                bucket = .other
            }
            counts[bucket, default: 0] += 1
        }
        return ScriptBucket.allCases.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? .other
    }

    private static func isNovelRefusal(output: String, input: String) -> Bool {
        let wordCount = output.split { $0.isWhitespace }.count
        guard wordCount < 15 else { return false }

        let templates = [
            "I can't help", "I cannot", "I'm sorry but I can't", "Sorry I can't",
            "抱歉，我", "很抱歉", "對不起，我無法",
        ]
        let normalizedOutput = normalizedPrefix(output)
        let normalizedInput = normalizedPrefix(input)
        guard let matched = templates.first(where: { normalizedOutput.hasPrefix(normalizedPrefix($0)) }) else {
            return false
        }
        return !normalizedInput.hasPrefix(normalizedPrefix(matched))
    }

    private static func normalizedPrefix(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
