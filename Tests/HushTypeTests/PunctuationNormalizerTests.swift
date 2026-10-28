import XCTest
@testable import HushType

final class PunctuationNormalizerTests: XCTestCase {

    func testOffModeIsPassthrough() {
        let text = "  你好，世界。 right, ok  "
        XCTAssertEqual(PunctuationNormalizer.apply(text, mode: .off), text)
    }

    func testEmptyInputAllModes() {
        for mode: PunctuationMode in [.soft, .hard, .off] {
            XCTAssertEqual(PunctuationNormalizer.apply("", mode: mode), "")
        }
    }

    func testSoftDropsFullwidthInlineBetweenHan() {
        XCTAssertEqual(PunctuationNormalizer.apply("今天，明天、後天；大後天：好", mode: .soft), "今天明天後天大後天好")
    }

    func testSoftKeepsSentenceEnders() {
        XCTAssertEqual(PunctuationNormalizer.apply("你好，世界。真的嗎？對！", mode: .soft), "你好世界。真的嗎？對！")
    }

    func testSoftDropsAsciiInlineOnlyNextToHan() {
        XCTAssertEqual(PunctuationNormalizer.apply("你好,世界", mode: .soft), "你好世界")
        XCTAssertEqual(PunctuationNormalizer.apply("我說 right, for sure", mode: .soft), "我說 right, for sure")
    }

    func testSoftPreservesItnThousandsAndDecimals() {
        XCTAssertEqual(PunctuationNormalizer.apply("預算10,000元", mode: .soft), "預算10,000元")
        XCTAssertEqual(PunctuationNormalizer.apply("比例3.5倍", mode: .soft), "比例3.5倍")
        XCTAssertEqual(PunctuationNormalizer.apply("時間: 10:30", mode: .soft), "時間 10:30")
    }

    func testRemovalAtLatinBoundaryLeavesOneSpace() {
        XCTAssertEqual(PunctuationNormalizer.apply("Hello，世界", mode: .soft), "Hello 世界")
        XCTAssertEqual(PunctuationNormalizer.apply("你好，world", mode: .soft), "你好 world")
        XCTAssertEqual(PunctuationNormalizer.apply("共10，個", mode: .soft), "共10 個")
    }

    func testHardDropsEndersAndLeavesGap() {
        XCTAssertEqual(PunctuationNormalizer.apply("你好，世界。再見！", mode: .hard), "你好世界 再見")
    }

    func testHardDropsBracketsAndTrims() {
        XCTAssertEqual(PunctuationNormalizer.apply("「你好」", mode: .hard), "你好")
        XCTAssertEqual(PunctuationNormalizer.apply("【重點】內容", mode: .hard), "重點內容")
    }

    func testSoftKeepsBrackets() {
        XCTAssertEqual(PunctuationNormalizer.apply("「你好」", mode: .soft), "「你好」")
    }

    func testPunctuationOnlyInput() {
        XCTAssertEqual(PunctuationNormalizer.apply("，，，", mode: .soft), "")
        XCTAssertEqual(PunctuationNormalizer.apply("。", mode: .soft), "。")
        XCTAssertEqual(PunctuationNormalizer.apply("。", mode: .hard), "")
    }

    func testCollapsesSpacesAndTrims() {
        XCTAssertEqual(PunctuationNormalizer.apply("  你好    世界  ", mode: .soft), "你好 世界")
    }
}
