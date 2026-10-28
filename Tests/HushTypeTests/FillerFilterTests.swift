import XCTest
@testable import HushType

final class FillerFilterTests: XCTestCase {

    private func assertDrops(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FillerFilter.keep(text), "expected drop: \"\(text)\"", file: file, line: line)
    }

    private func assertKeeps(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(FillerFilter.keep(text), "expected keep: \"\(text)\"", file: file, line: line)
    }

    func testEmptyAndWhitespaceOnlyAreDropped() {
        assertDrops("")
        assertDrops("   ")
        assertDrops("\n\t ")
    }

    func testChineseFillersAreDropped() {
        for text in ["呃", "呃。", "嗯，", "嗯嗯嗯。", "啊", "哦,", "哎.", "ㄜ", "呃。  "] {
            assertDrops(text)
        }
    }

    func testChineseFillerRequiresWholeSegment() {
        assertKeeps("呃, 我們")
        assertKeeps("嗯 好的")
        assertKeeps("啊哈")
    }

    func testEnglishFillersAreDroppedCaseInsensitively() {
        for text in ["Um.", "um.", "UM", "Uh,", "ah", "Mm.", "hm", "Er,"] {
            assertDrops(text)
        }
    }

    func testEnglishFillerRequiresWholeSegment() {
        assertKeeps("Umbrella")
        assertKeeps("um, okay")
        assertKeeps("er the")
    }

    func testLonePunctuationIsDropped() {
        for text in [".", "，", "。。", "?!", "—"] {
            assertDrops(text)
        }
    }

    func testShortSegmentsWithContentAreKept() {
        assertKeeps("好")
        assertKeeps("好。")
        assertKeeps("OK.")
        assertKeeps("OK")
        assertKeeps("呃?") // "?" is not in rule 1's trailing set and 呃 is a CJK ideograph
    }

    func testOrdinarySentencesAreKept() {
        assertKeeps("今天天氣很好。")
        assertKeeps("Let's get started.")
    }

    func testKatakanaOnlyShortSegmentIsKept() {
        // Kana counts as a letter, so rule 3 does not drop it.
        assertKeeps("ええ")
    }
}
