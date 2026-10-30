import Foundation

/// Both recognizers see the original Character buffer, never each other's output.
enum NumberNormalizer {
    struct Result {
        let text: String
        let applied: Bool
        let note: String
        let edits: [ITNEdit]
    }
    static func normalize(_ input: String) -> Result {
        normalize(input, script: ScriptDetector.detect(input))
    }
    static func normalize(_ input: String, script: Script) -> Result {
        guard script == .zh || script == .other else {
            return Result(text: input, applied: false, note: "no-op", edits: [])
        }
        let chars = Array(input)
        var proposed = script == .zh ? ChineseNumberITN.edits(in: chars) : []
        proposed += EnglishNumberITN.edits(in: chars)
        let edits = ITNMerge.validEdits(proposed, in: chars)
        let text = ITNMerge.apply(edits, to: chars)
        let kinds = Set(edits.map { $0.kind.rawValue }).sorted().joined(separator: ",")
        return Result(text: text, applied: text != input,
                      note: edits.isEmpty ? "no-op" : "applied: \(kinds)", edits: edits)
    }
}
