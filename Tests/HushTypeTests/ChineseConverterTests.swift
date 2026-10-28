import XCTest
@testable import HushType

final class ChineseConverterTests: XCTestCase {

    private func requireOpenCC() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/opt/homebrew/bin/opencc"),
            "opencc is not installed at /opt/homebrew/bin/opencc"
        )
    }

    func testDisabledIsPassthrough() {
        XCTAssertEqual(ChineseConverter.convert("数据学习", enabled: false), "数据学习")
    }

    func testEmptyInputIsPassthrough() {
        XCTAssertEqual(ChineseConverter.convert("", enabled: true), "")
    }

    func testEnglishAndSymbolsAreUntouched() {
        XCTAssertEqual(ChineseConverter.convert("Hello, world 123", enabled: true), "Hello, world 123")
    }

    func testJapaneseIsNotConverted() {
        // Kana present => ScriptDetector says .ja => gate returns before OpenCC.
        XCTAssertEqual(ChineseConverter.convert("本当にありがとう", enabled: true), "本当にありがとう")
    }

    func testKoreanIsNotConverted() {
        XCTAssertEqual(ChineseConverter.convert("大韓민국", enabled: true), "大韓민국")
    }

    func testSimplifiedToTaiwanTraditional() throws {
        try requireOpenCC()
        XCTAssertEqual(ChineseConverter.convert("我们在台湾开会", enabled: true), "我們在臺灣開會")
    }

    func testTaiwanPhraseConversion() throws {
        try requireOpenCC()
        XCTAssertEqual(ChineseConverter.convert("数据学习", enabled: true), "資料學習")
        XCTAssertEqual(ChineseConverter.convert("软件", enabled: true), "軟體")
    }

    func testTraditionalInputIsStable() throws {
        try requireOpenCC()
        XCTAssertEqual(ChineseConverter.convert("我們在臺灣開會", enabled: true), "我們在臺灣開會")
    }

    func testMixedChineseAndLatinKeepsLatin() throws {
        try requireOpenCC()
        XCTAssertEqual(ChineseConverter.convert("这个 deal 很好", enabled: true), "這個 deal 很好")
    }
}
