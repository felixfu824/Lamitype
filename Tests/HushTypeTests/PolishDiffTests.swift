import XCTest
@testable import HushType

final class PolishDiffTests: XCTestCase {

    func testIdenticalTextIsSingleEqualSegment() {
        XCTAssertEqual(PolishDiff.segments(original: "Hello 世界", polished: "Hello 世界"), [.equal("Hello 世界")])
    }

    func testBothEmptyYieldsNoSegments() {
        XCTAssertEqual(PolishDiff.segments(original: "", polished: ""), [])
    }

    func testPureInsertionAndDeletion() {
        XCTAssertEqual(PolishDiff.segments(original: "", polished: "abc"), [.insert("abc")])
        XCTAssertEqual(PolishDiff.segments(original: "abc", polished: ""), [.delete("abc")])
    }

    func testWordLevelReplacementOrdersDeleteBeforeInsert() {
        XCTAssertEqual(
            PolishDiff.segments(original: "I has apple", polished: "I have apple"),
            [.equal("I "), .delete("has"), .insert("have"), .equal(" apple")]
        )
    }

    func testCJKDiffsPerCharacter() {
        XCTAssertEqual(
            PolishDiff.segments(original: "我門好", polished: "我們好"),
            [.equal("我"), .delete("門"), .insert("們"), .equal("好")]
        )
    }

    func testPunctuationOnlyFixSurfacesPrecisely() {
        XCTAssertEqual(
            PolishDiff.segments(original: "你好,", polished: "你好，"),
            [.equal("你好"), .delete(","), .insert("，")]
        )
    }

    func testSegmentsReconstructBothSides() throws {
        let original = "今天我們要討論 the roadmap 的事情"
        let polished = "今天我們要討論 the product roadmap 的事。"
        let segments = try XCTUnwrap(PolishDiff.segments(original: original, polished: polished))
        var rebuiltOriginal = "", rebuiltPolished = ""
        for segment in segments {
            switch segment {
            case .equal(let t): rebuiltOriginal += t; rebuiltPolished += t
            case .delete(let t): rebuiltOriginal += t
            case .insert(let t): rebuiltPolished += t
            }
        }
        XCTAssertEqual(rebuiltOriginal, original)
        XCTAssertEqual(rebuiltPolished, polished)
    }

    func testTokenCapReturnsNil() {
        let long = String(repeating: "好", count: 2501)
        XCTAssertNil(PolishDiff.segments(original: long, polished: "好"))
        XCTAssertNil(PolishDiff.segments(original: "好", polished: long))
        XCTAssertNil(PolishDiff.attributed(original: long, polished: "好"))
    }

    func testTokenCapBoundaryIsInclusive() {
        let atCap = String(repeating: "好", count: 2500)
        XCTAssertEqual(PolishDiff.segments(original: atCap, polished: ""), [.delete(atCap)])
    }

    func testAttributedMarksDeletionsAndInsertions() throws {
        let attributed = try XCTUnwrap(PolishDiff.attributed(original: "I has apple", polished: "I have apple"))
        XCTAssertEqual(String(attributed.characters), "I hashave apple")
        let struck = attributed.runs.filter { $0.strikethroughStyle != nil }
        let underlined = attributed.runs.filter { $0.underlineStyle != nil }
        XCTAssertEqual(struck.map { String(attributed[$0.range].characters) }, ["has"])
        XCTAssertEqual(underlined.map { String(attributed[$0.range].characters) }, ["have"])
    }

    // MARK: - revertingNiSwaps

    func testRevertsNiSwapToNi() {
        XCTAssertEqual(PolishDiff.revertingNiSwaps(original: "妳好嗎", polished: "你好嗎"), "妳好嗎")
        XCTAssertEqual(PolishDiff.revertingNiSwaps(original: "妳好嗎", polished: "您好嗎"), "妳好嗎")
    }

    func testRevertKeepsOtherFixes() {
        XCTAssertEqual(
            PolishDiff.revertingNiSwaps(original: "妳說的話不對", polished: "你說的話不對。"),
            "妳說的話不對。"
        )
    }

    func testNoRevertWithoutNiInOriginal() {
        XCTAssertEqual(PolishDiff.revertingNiSwaps(original: "你好嗎", polished: "您好嗎"), "您好嗎")
    }

    func testNoRevertForNonNiReplacementOrLengthMismatch() {
        XCTAssertEqual(PolishDiff.revertingNiSwaps(original: "妳好", polished: "他好"), "他好")
        XCTAssertEqual(PolishDiff.revertingNiSwaps(original: "妳妳好", polished: "你好"), "你好")
    }

    func testRevertReturnsPolishedWhenOverTokenCap() {
        let original = "妳" + String(repeating: "好", count: 2500)
        let polished = "你" + String(repeating: "好", count: 2500)
        XCTAssertEqual(PolishDiff.revertingNiSwaps(original: original, polished: polished), polished)
    }
}
