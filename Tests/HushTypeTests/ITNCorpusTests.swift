import XCTest
@testable import HushType

/// Acceptance gates 2 and 5 of `Product_WS/SPEC_itn-span.md` against the real `NumberNormalizer`.
///
/// The corpus lives in `Fixtures/itn_corpus.json` and is loaded through `#filePath`, so no
/// Package.swift resource entry is needed. Scoring follows spec section 6:
/// - keep case: output must equal the input (any change is a corruption)
/// - convert case: output must equal one of `expect`; a value-equal format difference is a miss,
///   a produced number that no `expect` contains is a corruption
final class ITNCorpusTests: XCTestCase {

    // MARK: Corpus

    struct Case: Decodable {
        let id: String
        let lang: String
        let script: String
        let group: String
        let input: String
        let expect: [String]
        let keep: Bool
    }

    static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/itn_corpus.json")

    static let corpus: [Case] = {
        do {
            return try JSONDecoder().decode([Case].self, from: Data(contentsOf: corpusURL))
        } catch {
            fatalError("cannot load \(corpusURL.path): \(error)")
        }
    }()

    // MARK: Signature (port of harness/server.py `signature()`; 万 and 亿 added for Simplified)

    private static let numToken = try! NSRegularExpression(
        pattern: #"-?\$?\d[\d,]*(?:\.\d+)*(?::\d\d)?%?(?:萬|万|億|亿)?(?:st|nd|rd|th)?"#
            + #"|[零〇一二三四五六七八九十百千萬万億亿兩两幺]+"#
            + #"|\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|"#
            + #"sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|"#
            + #"thousand|million|billion|first|second|third|point|percent)\b"#,
        options: [.caseInsensitive])

    /// The number-bearing parts of a text, in order, lower-cased, commas removed.
    static func signature(_ text: String) -> [String] {
        let ns = text as NSString
        return numToken.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased().replacingOccurrences(of: ",", with: "")
        }
    }

    /// Signature tokens that are digit numbers (the ones a conversion produces).
    static func digitTokens(_ text: String) -> Set<String> {
        Set(signature(text).filter { tok in
            guard let first = tok.drop(while: { $0 == "-" || $0 == "$" }).first else { return false }
            return first.isASCII && first.isNumber
        })
    }

    // MARK: One pass over the corpus, shared by every test

    struct Row {
        let c: Case
        let output: String
        let exact: Bool          // convert case: output equals one of expect
        let keepChanged: Bool    // keep case: output differs from input
        let valueCorrupt: Bool   // convert case: produced a number that no expect contains
    }

    struct Run {
        let rows: [Row]
        var keepRows: [Row] { rows.filter { $0.c.keep } }
        var convertRows: [Row] { rows.filter { !$0.c.keep } }
        var keepOK: Int { keepRows.filter { !$0.keepChanged }.count }
        var exactCount: Int { convertRows.filter { $0.exact }.count }
        var exactRate: Double { convertRows.isEmpty ? 1 : Double(exactCount) / Double(convertRows.count) }
        var corruptions: [Row] { rows.filter { $0.keepChanged || $0.valueCorrupt } }
        var misses: [Row] { convertRows.filter { !$0.exact } }
    }

    static let run: Run = {
        var rows: [Row] = []
        for c in corpus {
            let out = NumberNormalizer.normalize(c.input).text
            if c.keep {
                rows.append(Row(c: c, output: out, exact: out == c.input,
                                keepChanged: out != c.input, valueCorrupt: false))
            } else {
                let exact = c.expect.contains(out)
                var corrupt = false
                if !exact && out != c.input {
                    let produced = digitTokens(out).subtracting(digitTokens(c.input))
                    corrupt = !produced.isEmpty
                        && !c.expect.contains { produced.isSubset(of: digitTokens($0)) }
                }
                rows.append(Row(c: c, output: out, exact: exact, keepChanged: false, valueCorrupt: corrupt))
            }
        }
        let run = Run(rows: rows)
        print("ITN corpus: \(rows.count) cases | keep \(run.keepOK)/\(run.keepRows.count) unchanged"
              + " | convert \(run.exactCount)/\(run.convertRows.count) exact"
              + " (\(String(format: "%.1f", run.exactRate * 100))%)"
              + " | corruptions \(run.corruptions.count) | misses \(run.misses.count)")
        for r in run.corruptions {
            print("CORRUPT \(r.c.id) [\(r.c.group)] in=\(r.c.input) out=\(r.output) expect=\(r.c.expect)")
        }
        for r in run.misses {
            print("MISS \(r.c.id) [\(r.c.group)] in=\(r.c.input) out=\(r.output) expect=\(r.c.expect)")
        }
        return run
    }()

    private func describe(_ rows: [Row], limit: Int = 25) -> String {
        rows.prefix(limit).map { "\($0.c.id) [\($0.c.group)] in=\($0.c.input) out=\($0.output)" }
            .joined(separator: "\n")
    }

    // MARK: Corpus shape

    func testCorpusCoverage() {
        let corpus = Self.corpus
        XCTAssertGreaterThanOrEqual(corpus.count, 350)
        XCTAssertEqual(Set(corpus.map(\.id)).count, corpus.count, "duplicate ids")
        XCTAssertEqual(Set(corpus.map(\.input)).count, corpus.count, "duplicate inputs")
        for c in corpus where c.keep {
            XCTAssertEqual(c.expect, [c.input], "keep case \(c.id) must expect its own input")
        }
        for c in corpus where !c.keep {
            XCTAssertFalse(c.expect.isEmpty, "convert case \(c.id) has no expectation")
        }
    }

    // MARK: Gate 2

    func testEveryKeepCaseIsUnchanged() {
        let changed = Self.run.keepRows.filter { $0.keepChanged }
        XCTAssertEqual(changed.count, 0, "keep cases changed:\n" + describe(changed))
    }

    func testConvertCasesMatchAtLeast95Percent() {
        let run = Self.run
        XCTAssertGreaterThanOrEqual(
            run.exactRate, 0.95,
            "\(run.exactCount)/\(run.convertRows.count) convert cases exact; misses:\n" + describe(run.misses))
    }

    func testZeroCorruptions() {
        XCTAssertEqual(Self.run.corruptions.count, 0, "corruptions:\n" + describe(Self.run.corruptions))
    }

    // MARK: Gate 5 on the corpus

    func testIdempotentOnCorpus() {
        var failures: [String] = []
        for r in Self.run.rows {
            let again = NumberNormalizer.normalize(r.output).text
            if again != r.output { failures.append("\(r.c.id) once=\(r.output) twice=\(again)") }
        }
        XCTAssertEqual(failures.count, 0, "not idempotent:\n" + failures.prefix(25).joined(separator: "\n"))
    }

    func testEditsReconstructInputAndHaveNoOverlap() {
        var failures: [String] = []
        for c in Self.corpus {
            failures += Self.editProblems(for: c.input).map { "\(c.id): \($0)" }
        }
        XCTAssertEqual(failures.count, 0, "edit problems:\n" + failures.prefix(25).joined(separator: "\n"))
    }

    /// Facade result invariants plus raw recognizer output (before `ITNMerge` drops anything).
    static func editProblems(for input: String) -> [String] {
        var problems: [String] = []
        let chars = Array(input)
        let result = NumberNormalizer.normalize(input)

        // Outside-span identity: swapping every replacement back for its original gives the input.
        let reverted = result.edits.map {
            ITNEdit(range: $0.range, original: $0.original, replacement: $0.original,
                    kind: $0.kind, language: $0.language, note: $0.note)
        }
        if ITNMerge.apply(reverted, to: chars) != input { problems.append("outside-span identity broken for \(input)") }
        if ITNMerge.apply(result.edits, to: chars) != result.text { problems.append("edits do not rebuild output for \(input)") }
        problems += structural(result.edits, in: chars, label: "facade", input: input)

        // Raw recognizers: each is internally disjoint, and zh and en never overlap each other.
        let zh = ChineseNumberITN.edits(in: chars)
        let en = EnglishNumberITN.edits(in: chars)
        problems += structural(zh, in: chars, label: "zh", input: input)
        problems += structural(en, in: chars, label: "en", input: input)
        for a in zh {
            for b in en where a.range.overlaps(b.range) {
                problems.append("zh \(a.range) and en \(b.range) overlap in \(input)")
            }
        }
        return problems
    }

    private static func structural(_ edits: [ITNEdit], in chars: [Character], label: String, input: String) -> [String] {
        var problems: [String] = []
        for (i, e) in edits.enumerated() {
            if e.range.isEmpty || e.range.lowerBound < 0 || e.range.upperBound > chars.count {
                problems.append("\(label) edit out of bounds \(e.range) in \(input)")
                continue
            }
            if String(chars[e.range]) != e.original { problems.append("\(label) original mismatch at \(e.range) in \(input)") }
            if e.replacement.contains(where: { ITNMerge.chineseNumeralCharacters.contains($0) }) {
                problems.append("\(label) replacement keeps a numeral character: \(e.replacement) in \(input)")
            }
            if i > 0 && edits[i - 1].range.upperBound > e.range.lowerBound {
                problems.append("\(label) edits unsorted or overlapping at \(e.range) in \(input)")
            }
        }
        return problems
    }

    // MARK: Fuzz (spec 5: fixed seed, 20,000 strings, lengths 0-60 weighted towards 0-3)

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let fuzzTokens: [String] = {
        let numerals = Array("零〇一二三四五六七八九十百千兩两萬万億亿幺")
        let words = Array("點点分負负年月號号塊块度歲岁個个第之比到至")
        let digits = Array("0123456789")
        let latin = ["one", "two", "three", "four", "five", "nine", "ten", "twelve", "twenty", "thirty", "forty",
                     "ninety", "hundred", "thousand", "million", "billion", "point", "percent", "dollars", "cents",
                     "pm", "am", "oh", "first", "second", "third", "nineteen", "iPhone", "Q", "N", "email", "iPad",
                     "at", "to", "of", "the", "and", "a", "Main", "Street", "version", "May"]
        let punct = ["，", "。", "、", " ", "-", ".", ":", "$", "%", "~", "～", "!", "?", ",", "\n", "(", ")"]
        let emoji = ["😀", "👍🏽", "🇹🇼", "👨‍👩‍👧", "é", "ñ"]
        return numerals.map(String.init) + words.map(String.init) + digits.map(String.init) + latin + punct + emoji
    }()

    static func fuzzStrings(count: Int = 20_000) -> [String] {
        var rng = SplitMix64(state: 0x1754_5EED_2026_1030)
        var out: [String] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let target = Int.random(in: 0...1, using: &rng) == 0
                ? Int.random(in: 0...3, using: &rng)
                : Int.random(in: 4...60, using: &rng)
            var s = ""
            while s.count < target { s += fuzzTokens[Int.random(in: 0..<fuzzTokens.count, using: &rng)] }
            out.append(s)
        }
        return out
    }

    func testFuzzNoCrashIdempotentAndEditsConsistent() {
        var failures: [String] = []
        for s in Self.fuzzStrings() {
            let once = NumberNormalizer.normalize(s).text
            let twice = NumberNormalizer.normalize(once).text
            if once != twice { failures.append("not idempotent: \(s) -> \(once) -> \(twice)") }
            failures += Self.editProblems(for: s)
            // The explicit-script entry points must also hold for text the detector would route elsewhere.
            _ = NumberNormalizer.normalize(s, script: .zh)
            _ = NumberNormalizer.normalize(s, script: .other)
            _ = NumberNormalizer.normalize(s, script: .ja)
            _ = NumberNormalizer.normalize(s, script: .ko)
        }
        print("ITN fuzz: 20000 strings, failures \(failures.count)")
        XCTAssertEqual(failures.count, 0, "fuzz failures:\n" + failures.prefix(25).joined(separator: "\n"))
    }

    func testJapaneseAndKoreanAreUntouched() {
        XCTAssertEqual(NumberNormalizer.normalize("三日坊主", script: .ja).text, "三日坊主")
        XCTAssertEqual(NumberNormalizer.normalize("二十三個", script: .ko).text, "二十三個")
    }

    // MARK: Latency (spec 5: release build, median under 1 ms per 100 characters)

    func testLatency() {
        let inputs = Self.corpus.map(\.input)
        measure {
            for s in inputs { _ = NumberNormalizer.normalize(s) }
        }

        var perHundred: [Double] = []
        for s in inputs where !s.isEmpty {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<20 { _ = NumberNormalizer.normalize(s) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 20 / 1_000_000
            perHundred.append(ms * 100 / Double(s.count))
        }
        perHundred.sort()
        let median = perHundred[perHundred.count / 2]
        print("ITN latency: median \(String(format: "%.3f", median)) ms per 100 characters over \(perHundred.count) inputs")
        #if !DEBUG
        XCTAssertLessThan(median, 1.0)
        #endif
    }
}
