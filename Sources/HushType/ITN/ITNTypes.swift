import Foundation

/// Shared contract for span-based number conversion (ITN).
///
/// Each language recognizer scans the text, decides per number span whether
/// to convert it, verifies the converted value, and returns one `ITNEdit` per
/// converted span. Spans it decides to keep produce no edit. `NumberNormalizer`
/// merges the edits of all recognizers and rebuilds the text; everything
/// outside an edit is copied unchanged.
///
/// Offsets are Character (grapheme cluster) indices into `Array(text)`, never
/// UTF-16 offsets, so every recognizer and the merge step agree on positions.

enum ITNLanguage: String {
    case chinese
    case english
}

/// What a converted span was recognised as. Used for logs and tests only.
enum ITNKind: String {
    case count          // 12個, 1200塊, twelve folders → 12 folders
    case amount         // 4.5萬, $45,000
    case money          // five dollars → $5
    case percent        // 43.2%, 12.5%
    case decimal        // 42.195, 0.3
    case time           // 3:30, 9:15
    case date           // 12月31號
    case year           // 1990年, 1990
    case ordinal        // 第23, 23rd
    case digitString    // 0912345678, 921, 305
    case version        // 0.5.16
    case modelCode      // iPhone17, N2, Q3
    case rangeOrScore   // 10到15, 3比2
    case measure        // 3公斤, 32度, 6.7吋
}

struct ITNEdit: Equatable {
    /// Character range in `Array(text)` that this edit replaces.
    let range: Range<Int>
    /// The exact characters being replaced (must equal `text[range]`).
    let original: String
    /// The converted form. Must not contain Chinese numeral characters.
    let replacement: String
    let kind: ITNKind
    let language: ITNLanguage
    /// Short human-readable reason, for logs and test failure messages.
    let note: String
}

enum ITNMerge {
    /// Chinese numeral characters that must never survive inside a replacement.
    /// 萬/万/億/亿 are allowed: the amount format writes 4.5萬.
    static let chineseNumeralCharacters: Set<Character> = Set("零〇一二三四五六七八九十百千兩两")

    /// Validate and combine the edits of several recognizers.
    ///
    /// Drops any edit whose `original` does not match the text, whose range is
    /// out of bounds or empty, or whose replacement contains a Chinese numeral.
    /// Overlapping edits are all dropped: when two recognizers disagree about
    /// the same characters, leaving the spoken form is the safe outcome.
    static func validEdits(_ edits: [ITNEdit], in chars: [Character]) -> [ITNEdit] {
        let checked = edits.filter { e in
            e.range.lowerBound >= 0 && e.range.upperBound <= chars.count && !e.range.isEmpty
                && String(chars[e.range]) == e.original
                && !e.replacement.contains(where: { chineseNumeralCharacters.contains($0) })
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }

        var overlapping = Set<Int>()
        for i in checked.indices {
            for j in checked.indices where j > i {
                if checked[j].range.lowerBound >= checked[i].range.upperBound { break }
                overlapping.insert(i)
                overlapping.insert(j)
            }
        }
        return checked.indices.filter { !overlapping.contains($0) }.map { checked[$0] }
    }

    /// Rebuild the text from validated, sorted, disjoint edits.
    static func apply(_ edits: [ITNEdit], to chars: [Character]) -> String {
        var out = ""
        var pos = 0
        for e in edits {
            out.append(contentsOf: String(chars[pos..<e.range.lowerBound]))
            out.append(e.replacement)
            pos = e.range.upperBound
        }
        out.append(contentsOf: String(chars[pos..<chars.count]))
        return out
    }
}
