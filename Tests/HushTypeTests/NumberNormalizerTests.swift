import XCTest
@testable import HushType

/* Changed old expectations under frozen SPEC_itn-span v2:
 - 三個蘋果 and 我買了五本書 now stay: §4.1 small measure-word counts.
 - 二十五度, 今天三十二度, 三十公斤, 時速六十公里, 五公尺 now retain
   度/公斤/公里/公尺; unit abbreviations are no longer acceptable alternatives.
 - 三千五百元 and 一千元台幣 retain 元 (no NT$ alternative).
 - 預算一百二十萬到一百五十萬 and 三十到五十個人 retain 到 (no ~ rewrite).
 - 兩千三百萬, 應該是兩千三百萬, 兩千萬, 三千五百萬 require 萬 format;
   一億兩千萬 requires 1.2億, replacing all old compound/raw-digit alternatives.
 - 五千塊 now requires 5000塊 rather than allowMiss: unambiguous money count.
 - 應該是五百萬不對六百萬 and 預算一百萬不對一百二十萬 convert the final
   amount independently; both amounts now convert under v2.2 §9.8 (big amounts ignore following Han).
   Self-correction no longer skips an entire sentence (§3 span-local decisions).
 - 應該差不多 five million now requires 5 million: English runs inside Chinese.
 - 我一個人 is strictly KEEP (previously allowMiss): article 一 policy.
 - 百分之三十 and 百分之五點五 require 30% and 5.5% (no half conversion).
 - 晚上七點到九點 requires 晚上7點到9點; 七點半 requires 7:30;
   三月到五月 requires 3月到5月 (previously allowMiss).
 - Guard notes are now no-op or applied: kinds, never whole-sentence skip notes.
 - Very short input is tested without the former crash skip (§2a).
 Every other old corpus expectation is retained, with a single canonical format.
 */
final class NumberNormalizerTests: XCTestCase {
    func testOriginalCorpusUnderSpanPolicy() {
        let cases: [(String, String)] = [
            ("三個蘋果", "三個蘋果"),
            ("我買了五本書", "我買了五本書"),
            ("大概十個人", "大概10個人"),
            ("二十五度", "25度"),
            ("今天三十二度", "今天32度"),
            ("三十公斤", "30公斤"),
            ("三十歲", "30歲"),
            ("二零二五年", "2025年"),
            ("時速六十公里", "時速60公里"),
            ("五公尺", "5公尺"),
            ("一百二十萬", "120萬"),
            ("五百萬美金", "500萬美金"),
            ("三千五百元", "3500元"),
            ("預算一百二十萬到一百五十萬", "預算120萬到150萬"),
            ("大概五百萬左右", "大概500萬左右"),
            ("這案子大概五百萬美金", "這案子大概500萬美金"),
            ("五千塊", "5000塊"),
            ("一千元台幣", "1000元台幣"),
            ("兩千三百萬", "2300萬"),
            ("應該是兩千三百萬", "應該是2300萬"),
            ("兩千萬", "2000萬"),
            ("一億兩千萬", "1.2億"),
            ("三千五百萬", "3500萬"),
            ("大概有個一兩百萬吧", "大概有個一兩百萬吧"),
            ("三三兩兩的人", "三三兩兩的人"),
            ("一心一意", "一心一意"),
            ("九牛二虎之力", "九牛二虎之力"),
            ("一般來說", "一般來說"),
            ("三國演義", "三國演義"),
            ("九成九", "九成九"),
            ("萬一出事", "萬一出事"),
            ("千萬要小心", "千萬要小心"),
            ("他五度被提名", "他五度被提名"),
            ("再度出發", "再度出發"),
            ("第三度空間", "第三度空間"),
            ("又一度失敗", "又一度失敗"),
            ("應該是五百萬不對六百萬", "應該是500萬不對600萬"),
            ("預算一百萬不對一百二十萬", "預算100萬不對120萬"),
            ("這個 deal 大概五百萬美金", "這個 deal 大概500萬美金"),
            ("應該差不多 five million", "應該差不多 5 million"),
            ("我有 3 個 idea", "我有 3 個 idea"),
            ("KPI 是一百萬", "KPI 是100萬"),
            ("你好嗎", "你好嗎"),
            ("今天天氣不錯", "今天天氣不錯"),
            ("幫我打開設定", "幫我打開設定"),
            ("等我一下", "等我一下"),
            ("有一些問題", "有一些問題"),
            ("一點點而已", "一點點而已"),
            ("我一個人", "我一個人"),
            ("第一個", "第一個"),
            ("百分之三十", "30%"),
            ("百分之五點五", "5.5%"),
            ("三點一四", "3.14"),
            ("三十到五十個人", "30到50個人"),
            ("晚上七點到九點", "晚上7點到9點"),
            ("七點半", "7:30"),
            ("三月到五月", "3月到5月"),
        ]
        XCTAssertEqual(cases.count, 57)
        for (input, expected) in cases {
            let result = NumberNormalizer.normalize(input)
            XCTAssertEqual(result.text, expected, input)
            XCTAssertEqual(result.applied, input != expected, input)
            XCTAssertEqual(NumberNormalizer.normalize(result.text).text, result.text, "idempotence: \(input)")
        }
    }

    func testNotesAndEditMetadata() {
        XCTAssertEqual(NumberNormalizer.normalize("一心一意").note, "no-op")
        XCTAssertEqual(NumberNormalizer.normalize("再度出發").note, "no-op")
        let result = NumberNormalizer.normalize("🙂十二個")
        XCTAssertEqual(result.note, "applied: count")
        XCTAssertEqual(result.edits.first?.range, 1..<3)
        XCTAssertEqual(result.edits.first?.original, "十二")
        XCTAssertEqual(result.edits.first?.replacement, "12")
    }

    func testVeryShortInputIsNoOp() {
        for input in ["", "好", "一", "1", "🙂", "好啊"] {
            XCTAssertEqual(NumberNormalizer.normalize(input).text, input)
        }
    }

    func testScriptGatingAndBothRecognizers() {
        for script: Script in [.ja, .ko] {
            XCTAssertEqual(NumberNormalizer.normalize("十二個 twelve folders", script: script).text, "十二個 twelve folders")
        }
        XCTAssertEqual(NumberNormalizer.normalize("十二個 twelve folders", script: .zh).text, "12個 12 folders")
        XCTAssertEqual(NumberNormalizer.normalize("twelve folders", script: .other).text, "12 folders")
    }
}
