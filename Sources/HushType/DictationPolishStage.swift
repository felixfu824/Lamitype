import Foundation

enum DictationPolishStage {
    enum Outcome: Equatable {
        case polished(changed: Bool)
        case keptRaw(reason: String)
    }

    struct Result {
        let text: String
        let outcome: Outcome
        let elapsed: TimeInterval
    }

    static func apply(
        _ text: String,
        polish: (String) async -> PolishResult
    ) async -> Result {
        let start = Date()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(text: text, outcome: .keptRaw(reason: "empty"), elapsed: 0)
        }

        let outcome: Outcome
        let resultText: String
        switch await polish(text) {
        case .success(let polished, let changed):
            outcome = .polished(changed: changed)
            resultText = changed ? polished : text
        case .failure(let error):
            outcome = .keptRaw(reason: error.stableToken)
            resultText = text
        }
        return Result(
            text: resultText,
            outcome: outcome,
            elapsed: Date().timeIntervalSince(start)
        )
    }
}
