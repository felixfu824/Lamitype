import XCTest
@testable import HushType

/// Regression corpus for `NumberNormalizer`, ported from the retired standalone
/// harness `scripts/test_number_normalizer.swift` (57 cases, same inputs and
/// scoring rules) so it now runs against the real module instead of a copy.
///
/// Scoring rules (unchanged from the harness):
/// - `.keep`      : output must equal input (anything else is CORRUPT)
/// - `.allowMiss` : unchanged is acceptable; a changed output must not trip any
///                  `OutputGuard` check (partial conversion, currency symbol,
///                  non-numeric drift)
/// - `.oneOf`     : output must be one of the listed forms
final class NumberNormalizerTests: XCTestCase {

    private enum Rule {
        case keep
        case allowMiss
        case oneOf([String])
    }

    private struct Case {
        let input: String
        let rule: Rule
    }

    private func check(_ cases: [Case], file: StaticString = #filePath, line: UInt = #line) {
        for c in cases {
            let res = NumberNormalizer.normalize(c.input)
            switch c.rule {
            case .keep:
                XCTAssertEqual(res.text, c.input, "must not touch: \(c.input) (note: \(res.note))", file: file, line: line)
                XCTAssertFalse(res.applied, "keep case reported applied: \(c.input)", file: file, line: line)
            case .allowMiss:
                if res.text == c.input {
                    XCTAssertFalse(res.applied, "unchanged output reported applied: \(c.input)", file: file, line: line)
                } else {
                    XCTAssertFalse(OutputGuard.hasPartialConversion(res.text), "partial conversion: \(c.input) -> \(res.text)", file: file, line: line)
                    XCTAssertFalse(OutputGuard.hasCurrencySymbol(res.text), "currency symbol: \(c.input) -> \(res.text)", file: file, line: line)
                    XCTAssertFalse(OutputGuard.nonNumericDrift(original: c.input, output: res.text), "non-numeric drift: \(c.input) -> \(res.text)", file: file, line: line)
                }
            case .oneOf(let options):
                XCTAssertTrue(options.contains(res.text), "\(c.input) -> \(res.text), expected one of \(options) (note: \(res.note))", file: file, line: line)
                XCTAssertTrue(res.applied, "converted case not reported applied: \(c.input)", file: file, line: line)
            }
        }
    }

    // MARK: - Corpus

    func testCountsAndMeasurements() {
        check([
            Case(input: "三個蘋果", rule: .oneOf(["3個蘋果"])),
            Case(input: "我買了五本書", rule: .oneOf(["我買了5本書"])),
            Case(input: "大概十個人", rule: .oneOf(["大概10個人"])),
            Case(input: "二十五度", rule: .oneOf(["25°", "25度"])),
            Case(input: "今天三十二度", rule: .oneOf(["今天32°", "今天32度"])),
            Case(input: "三十公斤", rule: .oneOf(["30kg", "30公斤"])),
            Case(input: "三十歲", rule: .oneOf(["30歲"])),
            Case(input: "二零二五年", rule: .oneOf(["2025年"])),
            Case(input: "時速六十公里", rule: .oneOf(["時速60km", "時速60公里"])),
            Case(input: "五公尺", rule: .oneOf(["5m", "5公尺"])),
        ])
    }

    func testBusinessNumbers() {
        check([
            Case(input: "一百二十萬", rule: .oneOf(["120萬"])),
            Case(input: "五百萬美金", rule: .oneOf(["500萬美金"])),
            Case(input: "三千五百元", rule: .oneOf(["3500元", "NT$3500"])),
            Case(input: "預算一百二十萬到一百五十萬", rule: .oneOf(["預算120萬到150萬", "預算120萬~150萬"])),
            Case(input: "大概五百萬左右", rule: .oneOf(["大概500萬左右"])),
            Case(input: "這案子大概五百萬美金", rule: .oneOf(["這案子大概500萬美金"])),
            Case(input: "五千塊", rule: .allowMiss),
            Case(input: "一千元台幣", rule: .oneOf(["1000元台幣", "NT$1000"])),
        ])
    }

    func testTrickyMagnitudes() {
        check([
            Case(input: "兩千三百萬", rule: .oneOf(["2300萬", "23000000"])),
            Case(input: "應該是兩千三百萬", rule: .oneOf(["應該是2300萬", "應該是23000000"])),
            Case(input: "兩千萬", rule: .oneOf(["2000萬", "20000000"])),
            Case(input: "一億兩千萬", rule: .oneOf(["1億2000萬", "12000萬", "120000000"])),
            Case(input: "三千五百萬", rule: .oneOf(["3500萬", "35000000"])),
        ])
    }

    func testIdiomsAreNeverTouched() {
        check([
            Case(input: "大概有個一兩百萬吧", rule: .keep),
            Case(input: "三三兩兩的人", rule: .keep),
            Case(input: "一心一意", rule: .keep),
            Case(input: "九牛二虎之力", rule: .keep),
            Case(input: "一般來說", rule: .keep),
            Case(input: "三國演義", rule: .keep),
            Case(input: "九成九", rule: .keep),
            Case(input: "萬一出事", rule: .keep),
            Case(input: "千萬要小心", rule: .keep),
            Case(input: "他五度被提名", rule: .keep),
            Case(input: "再度出發", rule: .keep),
            Case(input: "第三度空間", rule: .keep),
            Case(input: "又一度失敗", rule: .keep),
        ])
    }

    func testSelfCorrectionIsSkipped() {
        check([
            Case(input: "應該是五百萬不對六百萬", rule: .allowMiss),
            Case(input: "預算一百萬不對一百二十萬", rule: .allowMiss),
        ])
    }

    func testMixedLanguage() {
        check([
            Case(input: "這個 deal 大概五百萬美金", rule: .oneOf(["這個 deal 大概500萬美金"])),
            Case(input: "應該差不多 five million", rule: .allowMiss),
            Case(input: "我有 3 個 idea", rule: .keep),
            Case(input: "KPI 是一百萬", rule: .oneOf(["KPI 是100萬"])),
        ])
    }

    func testPlainTextIsUntouched() {
        check([
            Case(input: "你好嗎", rule: .keep),
            Case(input: "今天天氣不錯", rule: .keep),
            Case(input: "幫我打開設定", rule: .keep),
        ])
    }

    func testSmallNumberIdioms() {
        check([
            Case(input: "等我一下", rule: .keep),
            Case(input: "有一些問題", rule: .keep),
            Case(input: "一點點而已", rule: .keep),
            Case(input: "我一個人", rule: .allowMiss),
            Case(input: "第一個", rule: .keep),
        ])
    }

    func testDecimalsPercentsAndRanges() {
        check([
            Case(input: "百分之三十", rule: .oneOf(["30%", "百分之30"])),
            Case(input: "百分之五點五", rule: .oneOf(["5.5%", "百分之5.5"])),
            Case(input: "三點一四", rule: .oneOf(["3.14"])),
            Case(input: "三十到五十個人", rule: .oneOf(["30到50個人", "30~50個人"])),
        ])
    }

    func testTimeExpressions() {
        check([
            Case(input: "晚上七點到九點", rule: .allowMiss),
            Case(input: "七點半", rule: .allowMiss),
            Case(input: "三月到五月", rule: .allowMiss),
        ])
    }

    // MARK: - Result metadata (skip / no-op reasons)

    func testSkipNotesDistinguishGuards() {
        XCTAssertEqual(NumberNormalizer.normalize("一心一意").note, "skip (idiom)")
        XCTAssertEqual(NumberNormalizer.normalize("應該是五百萬不對六百萬").note, "skip (self-correction)")
        XCTAssertEqual(NumberNormalizer.normalize("再度出發").note, "skip (度-ambiguity)")
        XCTAssertEqual(NumberNormalizer.normalize("你好嗎").note, "no-op")
    }

    /// Inputs shorter than the guard patterns ("" or a single Han character
    /// such as a bare "好" from ASR) used to trap on a negative loop bound.
    func testVeryShortInputIsNoOp() {
        for input in ["", "好", "嗯", "五"] {
            let res = NumberNormalizer.normalize(input)
            XCTAssertEqual(res.text, input)
            XCTAssertFalse(res.applied)
        }
        XCTAssertFalse(OutputGuard.hasPartialConversion(""))
        XCTAssertFalse(OutputGuard.hasPartialConversion("5"))
    }
}
