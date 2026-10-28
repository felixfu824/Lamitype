import XCTest
@testable import HushType

final class ScriptDetectorTests: XCTestCase {

    func testEmptyAndSymbolsAreOther() {
        XCTAssertEqual(ScriptDetector.detect(""), .other)
        XCTAssertEqual(ScriptDetector.detect("   "), .other)
        XCTAssertEqual(ScriptDetector.detect("!!! 123 ..."), .other)
        XCTAssertEqual(ScriptDetector.detect("Hello, world"), .other)
    }

    func testHanOnlyIsChinese() {
        XCTAssertEqual(ScriptDetector.detect("你好"), .zh)
        XCTAssertEqual(ScriptDetector.detect("我們在臺灣開會。"), .zh)
    }

    func testMixedHanAndLatinIsChinese() {
        XCTAssertEqual(ScriptDetector.detect("Hello 世界"), .zh)
        XCTAssertEqual(ScriptDetector.detect("這個 deal 大概 500 萬"), .zh)
    }

    func testKanaMakesJapanese() {
        XCTAssertEqual(ScriptDetector.detect("こんにちは"), .ja)
        XCTAssertEqual(ScriptDetector.detect("カタカナ"), .ja)
        XCTAssertEqual(ScriptDetector.detect("本当です"), .ja)
        XCTAssertEqual(ScriptDetector.detect("ｱｲｳ"), .ja) // halfwidth katakana
        XCTAssertEqual(ScriptDetector.detect("ラーメン"), .ja) // prolonged sound mark U+30FC
    }

    func testKanaWinsOverHanAndLatin() {
        XCTAssertEqual(ScriptDetector.detect("iPhone 用戶 テスト"), .ja)
        XCTAssertEqual(ScriptDetector.detect("三日坊主ですね"), .ja)
    }

    func testHangulIsKoreanAndWinsOverHanja() {
        XCTAssertEqual(ScriptDetector.detect("안녕하세요"), .ko)
        XCTAssertEqual(ScriptDetector.detect("大韓민국"), .ko)
    }

    func testKanaWinsOverHangul() {
        XCTAssertEqual(ScriptDetector.detect("안녕 こんにちは"), .ja)
    }

    func testKatakanaMiddleDotAloneDoesNotReadAsJapanese() {
        // U+30FB is shared with Chinese foreign-name separators.
        XCTAssertEqual(ScriptDetector.detect("約翰・藍儂"), .zh)
        XCTAssertEqual(ScriptDetector.detect("・"), .other)
    }

    func testPureKanjiJapaneseIsIndistinguishableFromChinese() {
        // Documented limitation: no kana means no Japanese signal.
        XCTAssertEqual(ScriptDetector.detect("日本"), .zh)
    }

    func testIsHanRangeBoundaries() {
        XCTAssertTrue(ScriptDetector.isHan(0x4E00))
        XCTAssertTrue(ScriptDetector.isHan(0x9FFF))
        XCTAssertFalse(ScriptDetector.isHan(0x4DFF))
        XCTAssertFalse(ScriptDetector.isHan(0xA000))
        XCTAssertTrue(ScriptDetector.isHan(0x3400))   // Extension A
        XCTAssertTrue(ScriptDetector.isHan(0xF900))   // Compatibility Ideographs
        XCTAssertFalse(ScriptDetector.isHan(0x3042))  // hiragana あ
    }

    func testIsHanCharacterOverload() {
        XCTAssertTrue(ScriptDetector.isHan("字"))
        XCTAssertFalse(ScriptDetector.isHan("a"))
        XCTAssertFalse(ScriptDetector.isHan("，"))
    }
}
