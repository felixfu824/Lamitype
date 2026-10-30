import XCTest
@testable import HushType

final class EnglishNumberITNTests: XCTestCase {
    private func converted(_ input: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let chars = Array(input)
        let edits = EnglishNumberITN.edits(in: chars)
        XCTAssertEqual(ITNMerge.validEdits(edits, in: chars), edits, file: file, line: line)
        return ITNMerge.apply(edits, to: chars)
    }

    private func check(_ cases: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        for (input, expected) in cases {
            let output = converted(input, file: file, line: line)
            XCTAssertEqual(output, expected, input, file: file, line: line)
            XCTAssertEqual(converted(output, file: file, line: line), output,
                           "Idempotence: \(input)", file: file, line: line)
        }
    }

    func testSmallNumbersStayWithoutContext() {
        check([("zero", "zero"), ("one", "one"), ("two apples", "two apples"),
               ("three cats", "three cats"), ("four", "four"), ("five", "five"),
               ("six", "six"), ("seven", "seven"), ("eight", "eight"), ("nine", "nine")])
    }

    func testCardinalsAndGrouping() {
        check([("ten", "10"), ("eleven files", "11 files"), ("ninety nine", "99"),
               ("one hundred and five", "105"), ("nine thousand nine hundred", "9900"),
               ("ten thousand", "10,000"), ("forty five thousand", "45,000"),
               ("one million two hundred thirty four", "1,000,234"),
               ("one thousand and one", "1001")])
    }

    func testRoundAmounts() {
        check([("five million", "5 million"), ("two point three million", "2.3 million"),
               ("two million three hundred thousand", "2.3 million"),
               ("four billion", "4 billion"), ("two billion five hundred million", "2.5 billion"),
               ("one billion two hundred thirty four", "1,000,000,234")])
    }

    func testMoney() {
        check([("forty-five thousand dollars", "$45,000"), ("five dollars", "$5"),
               ("one dollar", "$1"), ("zero dollars", "$0"),
               ("five dollars and fifty cents", "$5.50"),
               ("one hundred dollars and five cents", "$100.05"),
               ("five dollars and zero cents", "$5.00"),
               ("two million dollars", "$2,000,000"), ("fifty cents", "$0.50"),
               ("five point five dollars", "$5.50")])
        check([("$five dollars", "$5"), ("$ five", "$ 5"),
               ("five dollars and twenty people", "$5 and 20 people")])
    }

    func testPercent() {
        check([("twelve point five percent", "12.5%"), ("five percent", "5%"),
               ("zero percent", "0%"), ("twenty five per cent", "25%"),
               ("at twelve point five percent", "at 12.5%"),
               ("at three thirty percent", "at three thirty percent")])
    }

    func testMeasurementUnits() {
        check([("five kilograms", "5 kilograms"), ("one meter", "1 meter"),
               ("two GB", "2 GB"), ("three degrees", "3 degrees"),
               ("zero seconds", "0 seconds"), ("one second", "1 second"), ("nine inches", "9 inches"),
               ("$five", "$5"), ("five%", "5%"), ("five %", "5 %")])
    }

    func testTimesWithMeridiemAndAt() {
        check([("three thirty pm", "3:30 pm"), ("at nine fifteen", "at 9:15"),
               ("at nine fifteen tomorrow", "at 9:15 tomorrow"),
               ("at nine oh five", "at 9:05"), ("three zero five AM", "3:05 AM"),
               ("at twelve forty five", "at 12:45"), ("nine pm", "9 pm"),
               ("three thirty", "three thirty"), ("at Nine Fifteen", "at Nine Fifteen"),
               ("at twenty four", "at 24"),
               ("at nine fifteen Plaza", "at nine fifteen Plaza"),
               ("three sixty pm", "three sixty pm"), ("twenty five thirty pm", "twenty five thirty pm")])
    }

    func testYears() {
        check([("nineteen ninety", "1990"), ("nineteen ninety nine", "1999"),
               ("twenty twenty six", "2026"), ("twenty oh five", "2005"),
               ("nineteen oh nine", "1909"), ("twenty four", "24"),
               ("nineteen hundred", "1900")])
    }

    func testOrdinals() {
        check([("first second third fourth fifth sixth seventh eighth ninth tenth",
                "first second third fourth fifth sixth seventh eighth ninth tenth"),
               ("the eleventh", "the 11th"), ("twenty third", "23rd"),
               ("the twenty fourth of May", "the 24th of May"),
               ("twenty-first", "21st"), ("one hundred and first", "101st"),
               ("one hundred twelfth", "112th"), ("twentieth", "20th")])
    }

    func testDigitStrings() {
        check([("one two three", "one two three"), ("zero nine one two three four", "091234"),
               ("oh one two", "oh one two"), ("one two", "one two"),
               ("My number is zero nine one two, three four five, six seven eight.",
                "My number is 0912345678."),
               ("call five five five one two three four", "call 5551234")])
    }

    func testVersions() {
        check([("version zero point five point sixteen", "version 0.5.16"),
               ("one point two point three", "1.2.3"),
               ("zero point zero five point one", "0.05.1"),
               ("zero point five point", "zero point five point")])
    }

    func testDecimals() {
        check([("zero point five", "0.5"), ("one point zero five", "1.05"),
               ("twelve point five", "12.5"), ("three point one four one five nine", "3.14159"),
               ("ten point twenty", "ten point twenty")])
    }

    func testIdiomsAndPronouns() {
        let cases = ["one-off", "cloud nine", "one of", "this one", "a second", "at once",
                     "one or two", "one another", "one by one"]
        check(cases.map { ($0, $0) })
        check([("One-off: buy twelve folders and this one", "One-off: buy 12 folders and this one"),
               ("cloud nine, twenty files", "cloud nine, 20 files")])
    }

    func testExistingDigitsStayExactlyAsWritten() {
        let cases = ["2026", "3:30", "$45,000", "120 million", "12.50 percent",
                     "v2.3.4", "00123", "2 point five", "2 point fifteen", "twenty 4", "3-five"]
        check(cases.map { ($0, $0) })
        check([("120 million and twelve", "120 million and twelve"),
               ("2026, twelve files", "2026, 12 files")])
    }

    func testHyphenatedNumbersAndOutsideCase() {
        check([("BUY forty-Five THOUSAND Dollars NOW", "BUY $45,000 NOW"),
               ("HELLO Twenty-one people. GOODBYE", "HELLO 21 people. GOODBYE"),
               ("forty-five-thousand", "45,000")])
    }

    func testMixedMandarinAndEmojiOffsets() {
        check([("這個 deal 大概 five million 美金", "這個 deal 大概 5 million 美金"),
               ("下午 three thirty 的 meeting", "下午 3:30 的 meeting"),
               ("👨‍👩‍👧‍👦👍🏽買 twelve 個 files，five dollars！", "👨‍👩‍👧‍👦👍🏽買 12 個 files，$5！"),
               ("下午 three oh five 的 meeting", "下午 3:05 的 meeting")])
    }

    func testGluedCodeSwitchingStays() {
        let cases = ["七點twenty", "twenty塊八", "6度七ten",
                     "twenty percent三", "twenty3", "3twenty", "twenty:30", "3:twenty",
                     "twenty%3", "twenty%三", "twenty.5", "twenty.五", ".twenty",
                     "forty〇個", "twelve〇年", "比八〇nineteen", "twenty:-5度", "twenty:+五度"]
        check(cases.map { ($0, $0) })
        let residual = ["%thirty比一度", "ten歲四零零5", "thirty号五点9", "、forty第幺八六", "7負ten点千0billion",
                        "thirty个6億", "thirty份點心", "負twenty度", "负twenty度", "five dollars-5度"]
        check(residual.map { ($0, $0) })
        check([("twelve,thirty个六億", "12,thirty个六億")])
    }

    func testSpacedCodeSwitchingStillConverts() {
        check([("我需要 twenty 份 copies", "我需要 20 份 copies"),
               ("七點 twenty", "七點 20"), ("twenty 塊八", "20 塊八"),
               ("6度七 ten", "6度七 10"), ("我有 twelve 個 files", "我有 12 個 files"),
               ("twenty percent 三", "20% 三"), ("twenty dollars 元", "$20 元"),
               ("ten %", "10 %"), ("twenty :", "20 :"), ("twenty:", "20:"),
               ("twenty%", "20%"), ("%twenty", "%20"), ("twenty。", "20。"),
               ("我需要twenty份copies", "我需要20份copies"), ("twelve美金", "12美金"),
               ("我需要twenty 份 copies", "我需要20 份 copies"),
               ("我需要 twenty份 copies", "我需要 20份 copies"),
               ("twenty dollars元", "$20元"), ("㐀twenty", "㐀20"), ("twenty㐀", "20㐀"),
               ("three point one four.", "3.14."), ("five dollars.", "$5.")])
    }

    func testMixedRecognizerIdempotence() {
        func normalizeBoth(_ input: String) -> String {
            let chars = Array(input)
            let proposed = ChineseNumberITN.edits(in: chars) + EnglishNumberITN.edits(in: chars)
            return ITNMerge.apply(ITNMerge.validEdits(proposed, in: chars), to: chars)
        }
        let chinese = ["七點", "塊八", "6度七", "我需要", "三萬五", "十二個", "負五度", "三"]
        let english = ["twenty", "ten", "five dollars", "twelve point five percent",
                       "one two three", "zero point five point sixteen"]
        var inputs = ["七點twenty", "twenty塊八", "6度七ten", "我需要 twenty 份 copies",
                      "%thirty比一度", "ten歲四零零5", "thirty号五点9", "、forty第幺八六",
                      "7負ten点千0billion", "twelve,thirty个六億", "負twenty度", "负twenty度", "five dollars負五度"]
        for zh in chinese {
            for en in english {
                inputs.append(contentsOf: [zh + en, en + zh, "\(zh) \(en)", "\(en) \(zh)",
                                          "\(zh).\(en)", "\(en):\(zh)", "\(zh)%\(en)"])
            }
        }
        for input in inputs {
            let once = normalizeBoth(input)
            XCTAssertEqual(normalizeBoth(once), once, input)
        }
    }

    func testRangesLinkSmallNumbers() {
        check([("two to twelve", "2 to 12"), ("twelve to two", "12 to 2"),
               ("one to two", "one to two"),
               ("this one to twelve", "this one to 12")])
    }

    func testMalformedRunsStay() {
        let cases = ["one hundred hundred", "five thousand million", "one and two",
                     "one point", "five dollars and one hundred cents", "one thousand zero hundred",
                     "five dollars and one hundred and one cents",
                     "one million million", "ten twenty thirty", "one point two point hundred"]
        check(cases.map { ($0, $0) })
    }

    func testEmptyAndShortInputs() {
        let cases = ["", "a", "I", "好", "🙂", ".", "at", "on", "one", "oh", "零"]
        check(cases.map { ($0, $0) })
    }

    func testSecondUnitAndOrdinalDisambiguation() {
        check([("a thirty second clip", "a 30 second clip"),
               ("twenty second timeout", "20 second timeout"), ("ninety second video", "90 second video"),
               ("ten second timeout", "10 second timeout"), ("two hundred second video", "200 second video"),
               ("one hundred second floor", "102nd floor"),
               ("twenty-second timeout", "22nd timeout"), ("twenty second of June", "22nd of June"),
               ("the twenty second floor", "the 22nd floor"), ("She came in thirty second.", "She came in 32nd."),
               ("finished twenty second yesterday", "finished 22nd yesterday"),
               ("twenty first-time users", "twenty first-time users")])
    }

    func testFractionsAndTitleCaseStay() {
        let cases = ["one hundredth of a second", "one thousandth", "one millionth", "one billionth",
                     "Twenty One Pilots played", "the Forty-Niners won", "I bought Twenty Dollars"]
        check(cases.map { ($0, $0) })
        check([("Twenty folders arrived", "20 folders arrived"), ("I need twenty folders", "I need 20 folders")])
    }

    func testThreeDigitStringsNeedACue() {
        check([("two three four people", "two three four people"), ("one two three", "one two three"),
               ("Room three oh five", "Room 305"), ("gate one two three", "gate 123"),
               ("flight one two three", "flight 123"), ("PIN one two three", "PIN 123"),
               ("one two three four", "1234"), ("extension one two three", "extension 123"),
               ("zip one two three", "zip 123")])
    }

    func testMoneyRangesAndBareCentsTail() {
        check([("five to ten dollars", "$5 to $10"), ("ten dollars to five", "$10 to $5"),
               ("five dollars to ten dollars", "$5 to $10"),
               ("fifty cents to ten dollars", "$0.50 to $10"),
               ("five dollars and fifty cents to ten dollars", "$5.50 to $10"),
               ("$five to ten dollars", "$5 to $10"),
               ("this one to ten dollars", "this one to ten dollars"),
               ("ten dollars and fifty", "$10 and fifty"),
               ("$10 and fifty", "$10 and fifty"),
               ("ten dollars and fifty cents", "$10.50"), ("nineteen ninety dollars", "nineteen ninety dollars"),
               ("nineteen ninety meters", "nineteen ninety meters")])
    }

    func testDottedMeridiemListsAndHundreds() {
        check([("eleven thirty five p.m.", "11:35 p.m."), ("three thirty a.m.", "3:30 a.m."),
               ("pages ten and twelve", "pages 10 and 12"), ("fifty and sixty people", "50 and 60 people"),
               ("one hundred and five", "105"), ("a hundred", "100"),
               ("fifteen hundred", "1500"), ("twelve hundred", "1200")])
    }

    func testHyphenatedNonNumberTokensStayEntirely() {
        let cases = ["Forty-Niners won", "the Forty-Niners won", "twenty-somethings",
                     "Seventy-Sixers", "watch Seventy-Sixers tonight", "pre-twenty-five",
                     "twenty-five-year-old", "non-twenty", "twenty-first-time"]
        check(cases.map { ($0, $0) })
        check([("twenty-five", "25"), ("twenty-first", "21st"),
               ("I need twenty-five folders", "I need 25 folders")])
    }

    func testIndefiniteArticleBeforeLargeScales() {
        check([("a thousand", "1000"), ("a thousand people", "1000 people"),
               ("a million dollars", "$1 million"), ("a billion", "1 billion"),
               ("a million", "1 million"), ("a billion dollars", "$1 billion"),
               ("a thousand dollars", "$1000"),
               ("a million dollars and fifty", "$1 million and fifty")])
    }

    func testDeterministicFuzzAndOutsideSpanIdentity() {
        var seed: UInt64 = 0x1977_1029
        let alphabet = ["zero", "one", "two", "twelve", "twenty", "ninety", "hundred", "million",
                        "point", "and", "first", "fourth", "dollars", "cents", "percent", "pm", "at",
                        "second", "thirty", "to", "a", "Twenty", "One", "Forty", "p.m.", "-time", "份", "塊", "八", "點",
                        "零", "一", "二", "十", "百", "千", "萬", "億", "兩", "两", "〇", "幺",
                        "點", "分", "負", "年", "月", "號", "塊", "0", "9", " ", "-", ".", ":", "👩🏽‍💻", "！"]
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed
        }
        for index in 0..<20_000 {
            let length = index % 2 == 0 ? Int(next() % 4) : Int(next() % 16)
            var input = ""
            for _ in 0..<length {
                input += alphabet[Int(next() % UInt64(alphabet.count))]
                if next() % 3 == 0 { input += " " }
            }
            let chars = Array(input.prefix(60))
            let edits = EnglishNumberITN.edits(in: chars)
            XCTAssertEqual(edits, EnglishNumberITN.edits(in: chars))
            XCTAssertEqual(ITNMerge.validEdits(edits, in: chars), edits)
            let output = ITNMerge.apply(edits, to: chars)
            XCTAssertEqual(converted(output), output, String(chars))
            var restored = Array(output)
            for edit in edits {
                let start = edit.range.lowerBound
                let end = start + edit.replacement.count
                restored.replaceSubrange(start..<end, with: Array(edit.original))
                // Restoring each edit returns the prefix to original offsets.
            }
            XCTAssertEqual(String(restored), String(chars))
        }
    }

    func testLatencyOnOneHundredCharacters() {
        let sentence = "Meet at nine fifteen pm and bring twenty four files; this deal costs five million dollars tomorrow. "
        XCTAssertEqual(sentence.count, 100)
        let chars = Array(sentence)
        _ = EnglishNumberITN.edits(in: chars) // Warm static tables.
        var samples: [Double] = []
        for _ in 0..<101 {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 { _ = EnglishNumberITN.edits(in: chars) }
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 10)
        }
        samples.sort()
        print("EnglishNumberITN 100-character median: \(samples[50]) ms per edits(in:) call")
        XCTAssertLessThan(samples[50], 1.0)
    }
}
