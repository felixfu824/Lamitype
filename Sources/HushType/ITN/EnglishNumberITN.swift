import Foundation

enum EnglishNumberITN {
    private typealias Parser = EnglishNumberParser
    private struct Token {
        let word: String
        let original: String
        let range: Range<Int>
    }
    private struct Candidate {
        let range: Range<Int>
        let number: Parser.Number?
        let protected: Bool
        var edit: ITNEdit?
    }

    private static let measurementUnits: Set<String> = [
        "mm", "cm", "m", "km", "mg", "g", "kg", "ml", "l", "kb", "mb", "gb", "tb",
        "millimeter", "millimeters", "centimeter", "centimeters", "meter", "meters",
        "metre", "metres", "kilometer", "kilometers", "kilometre", "kilometres",
        "gram", "grams", "kilogram", "kilograms", "milligram", "milligrams",
        "liter", "liters", "litre", "litres", "milliliter", "milliliters",
        "inch", "inches", "foot", "feet", "yard", "yards", "mile", "miles",
        "ounce", "ounces", "pound", "pounds", "degree", "degrees",
        "second", "seconds", "minute", "minutes", "hour", "hours",
        "hertz", "kilohertz", "megahertz", "gigahertz", "volt", "volts", "watt", "watts",
        "byte", "bytes", "kilobyte", "kilobytes", "megabyte", "megabytes", "gigabyte", "gigabytes"
    ]
    private static let idioms: [[String]] = [
        ["one", "off"], ["cloud", "nine"], ["one", "of"], ["this", "one"],
        ["a", "second"], ["at", "once"], ["one", "or", "two"],
        ["one", "another"], ["one", "by", "one"]
    ]
    private static let digitCues: Set<String> = ["number", "phone", "telephone", "call", "code",
        "extension", "ext", "room", "pin", "flight", "gate", "zip"]
    private static let ordinalFollowers: Set<String> = ["of", "place", "floor", "birthday", "century",
        "time", "row", "round", "anniversary", "edition"]
    private static let fractions: Set<String> = ["hundredth", "thousandth", "millionth", "billionth"]

    static func edits(in chars: [Character]) -> [ITNEdit] {
        let tokens = tokenize(chars)
        guard !tokens.isEmpty else { return [] }
        var protected = protectedTokens(tokens, chars)
        var candidates: [Candidate] = []
        var i = 0
        while i < tokens.count {
            guard candidateWord(i, tokens, chars) else { i += 1; continue }
            let start = i
            var end = i + 1
            while end < tokens.count && (joined(tokens[end - 1], tokens[end], chars)
                    || phoneSeparator(start, end, tokens, chars)) {
                let word = tokens[end].word
                if Parser.ordinals[tokens[end - 1].word] != nil { break }
                if word == "second", !ordinalSecond(start, end, tokens, chars) { break }
                if candidateWord(end, tokens, chars) || word == "point" { end += 1 }
                else if word == "and", end + 1 < tokens.count,
                        candidateWord(end + 1, tokens, chars),
                        joined(tokens[end], tokens[end + 1], chars) { end += 1 }
                else { break }
            }
            let words = tokens[start..<end].map(\.word)
            let number = Parser.number(words)
            let moneyTail = moneyTailEnd(end, tokens, chars)
            let candidate = recognize(start, end, tokens, chars, protected)
            if candidate.edit == nil, !candidate.protected, number == nil, words.contains("and") {
                var part = start
                for separator in start..<end where tokens[separator].word == "and" {
                    if part < separator { candidates.append(recognize(part, separator, tokens, chars, protected)) }
                    part = separator + 1
                }
                if part < end { candidates.append(recognize(part, end, tokens, chars, protected)) }
            } else { candidates.append(candidate) }
            if candidate.edit?.kind == .money, moneyTail == nil,
               let tail = bareMoneyTail(end, tokens, chars) { protected.formUnion(tail) }
            i = moneyTail.map { $0 + 1 } ?? end
            // A money edit may also consume a second number and the cents noun.
            if let upper = candidate.edit?.range.upperBound {
                while i < tokens.count && tokens[i].range.lowerBound < upper { i += 1 }
            }
        }

        // Link ranges on the original text. Protected spans never inherit a cue.
        if candidates.count >= 2 {
            for index in 0..<(candidates.count - 1) {
                let left = candidates[index]
                let right = candidates[index + 1]
                let leftEnd = left.edit?.range.upperBound ?? left.range.upperBound
                guard leftEnd <= right.range.lowerBound else { continue }
                let gap = String(chars[leftEnd..<right.range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard gap == "to" else { continue }
                if left.edit?.kind == .money || right.edit?.kind == .money {
                    if !left.protected, !right.protected, let a = left.number, let b = right.number,
                       var first = Parser.money(a.value, cents: a.decimal),
                       var second = Parser.money(b.value, cents: b.decimal) {
                        if dollarPrefix(left.range.lowerBound, chars) { first.removeFirst() }
                        if dollarPrefix(right.range.lowerBound, chars) { second.removeFirst() }
                        candidates[index].edit = makeEdit(left.edit?.range ?? left.range, first, .money, chars)
                        candidates[index + 1].edit = makeEdit(right.edit?.range ?? right.range, second, .money, chars)
                    } else {
                        candidates[index].edit = nil
                        candidates[index + 1].edit = nil
                    }
                    continue
                }
                guard !left.protected, !right.protected, left.edit != nil || right.edit != nil else { continue }
                for target in [index, index + 1] where candidates[target].edit == nil {
                    if let n = candidates[target].number {
                        candidates[target].edit = makeEdit(candidates[target].range,
                            Parser.grouped(n.plain), .rangeOrScore, chars)
                    }
                }
            }
        }
        return candidates.compactMap(\.edit)
    }

    private static func recognize(_ start: Int, _ end: Int, _ tokens: [Token],
                                  _ chars: [Character], _ protected: Set<Int>) -> Candidate {
        let range = tokens[start].range.lowerBound..<tokens[end - 1].range.upperBound
        let words = tokens[start..<end].map(\.word)
        let ordinalCompound = Parser.ordinals[tokens[end - 1].word] != nil
            && range.upperBound < chars.count && chars[range.upperBound] == "-"
        let blocked = ordinalCompound || words.contains(where: { fractions.contains($0) })
            || (start..<end).contains(where: { protected.contains($0) })
            || titleCaseRun(start, end, tokens, chars) || touchesExistingNumber(start, end, tokens, chars)
            || bareCurrencyContinuation(start, end, tokens, chars)
        var candidate = Candidate(range: range, number: Parser.number(words), protected: blocked, edit: nil)
        if !blocked, let result = classify(words, start, end, tokens, chars) {
            let editRange = range.lowerBound..<result.end
            if unsafeBoundary(editRange, chars) {
                return Candidate(range: range, number: nil, protected: true, edit: nil)
            }
            let edit = makeEdit(editRange, result.text, result.kind, chars)
            if result.kind == .money, let value = result.value {
                let semantic = Parser.Number(value: value, plain: Parser.decimalString(value),
                                             decimal: result.text.contains("."))
                candidate = Candidate(range: range, number: semantic, protected: false, edit: edit)
            } else { candidate.edit = edit }
        }
        if moneyTailEnd(end, tokens, chars) != nil && candidate.edit == nil {
            return Candidate(range: range, number: nil, protected: true, edit: nil)
        }
        return candidate
    }

    private static func candidateWord(_ index: Int, _ tokens: [Token], _ chars: [Character]) -> Bool {
        Parser.isNumber(tokens[index].word) || (tokens[index].word == "a" && index + 1 < tokens.count
            && (tokens[index + 1].word == "hundred" || Parser.scales[tokens[index + 1].word] != nil)
            && joined(tokens[index], tokens[index + 1], chars))
    }

    private static func ordinalSecond(_ start: Int, _ end: Int, _ tokens: [Token], _ chars: [Character]) -> Bool {
        if end - start == 1 && tokens[start].word == "one" { return false }
        let gap = String(chars[tokens[end - 1].range.upperBound..<tokens[end].range.lowerBound])
        if gap == "-" { return true }
        if end + 1 == tokens.count || !joined(tokens[end], tokens[end + 1], chars) { return true }
        if ordinalFollowers.contains(tokens[end + 1].word) { return true }
        let context = tokens[max(0, start - 3)..<start].map(\.word)
        if context.contains(where: { ["finished", "placed", "ranked"].contains($0) }) { return true }
        for pair in [["came", "in"], ["come", "in"], ["ended", "up"], ["in", "the"]] {
            if context.count >= 2 {
                for index in 0..<(context.count - 1) where Array(context[index...index + 1]) == pair { return true }
            }
        }
        return false
    }

    private static func titleCaseRun(_ start: Int, _ end: Int, _ tokens: [Token], _ chars: [Character]) -> Bool {
        let numberWords = tokens[start..<end].filter { Parser.isNumber($0.word) }
        guard !numberWords.isEmpty, numberWords.allSatisfy({ $0.original.first?.isUppercase == true }) else { return false }
        if numberWords.count > 1 { return true }
        guard start > 0 else { return false }
        let gap = chars[tokens[start - 1].range.upperBound..<tokens[start].range.lowerBound]
        return !gap.contains(where: { $0 == "." || $0 == "!" || $0 == "?" || $0 == "\n" })
    }

    private static func bareMoneyTail(_ end: Int, _ tokens: [Token], _ chars: [Character]) -> Range<Int>? {
        guard end + 2 < tokens.count, ["dollar", "dollars"].contains(tokens[end].word),
              tokens[end + 1].word == "and", joined(tokens[end], tokens[end + 1], chars),
              joined(tokens[end + 1], tokens[end + 2], chars) else { return nil }
        var upper = end + 2
        while upper < tokens.count, Parser.isNumber(tokens[upper].word) || tokens[upper].word == "point" {
            if upper > end + 2 && !joined(tokens[upper - 1], tokens[upper], chars) { break }
            upper += 1
        }
        guard upper > end + 2, upper == tokens.count || !joined(tokens[upper - 1], tokens[upper], chars) else { return nil }
        return (end + 2)..<upper
    }

    private static func bareCurrencyContinuation(_ start: Int, _ end: Int,
                                                  _ tokens: [Token], _ chars: [Character]) -> Bool {
        guard start > 0, tokens[start - 1].word == "and", joined(tokens[start - 1], tokens[start], chars),
              end == tokens.count || !joined(tokens[end - 1], tokens[end], chars) else { return false }
        let upper = tokens[start - 1].range.lowerBound
        let prefix = chars[max(0, upper - 32)..<upper]
        guard let dollar = prefix.lastIndex(of: "$") else { return false }
        var amount = String(prefix[(dollar + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        for scale in [" million", " billion", " trillion"] where amount.hasSuffix(scale) {
            amount.removeLast(scale.count)
            break
        }
        return amount.contains(where: isASCIIDigit)
            && amount.allSatisfy { isASCIIDigit($0) || $0 == "." || $0 == "," || $0.isWhitespace }
    }

    /// FIND the entire dollars-and-cents phrase even when its cents value is
    /// invalid. Rejection must not turn the tail into a separate money edit.
    private static func moneyTailEnd(_ end: Int, _ tokens: [Token], _ chars: [Character]) -> Int? {
        guard end + 2 < tokens.count, ["dollar", "dollars"].contains(tokens[end].word),
              tokens[end + 1].word == "and", joined(tokens[end], tokens[end + 1], chars),
              joined(tokens[end + 1], tokens[end + 2], chars) else { return nil }
        var i = end + 2
        while i < tokens.count, Parser.isNumber(tokens[i].word)
            || tokens[i].word == "point" || tokens[i].word == "and" {
            guard joined(tokens[i - 1], tokens[i], chars) else { return nil }
            i += 1
        }
        guard i > end + 2, i < tokens.count, ["cent", "cents"].contains(tokens[i].word),
              joined(tokens[i - 1], tokens[i], chars) else { return nil }
        return i
    }

    private static func phoneSeparator(_ start: Int, _ end: Int,
                                       _ tokens: [Token], _ chars: [Character]) -> Bool {
        guard end - start >= 3, singleDigits(tokens[start..<end].map(\.word)) != nil,
              let next = Parser.units[tokens[end].word], next < 10 else { return false }
        let gap = String(chars[tokens[end - 1].range.upperBound..<tokens[end].range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard gap == "," else { return false }
        return hasDigitCue(start, tokens)
    }

    private static func hasDigitCue(_ start: Int, _ tokens: [Token]) -> Bool {
        tokens[max(0, start - 5)..<start].contains { digitCues.contains($0.word) }
    }

    private struct Conversion {
        let text: String
        let kind: ITNKind
        let end: Int
        var value: Decimal? = nil
    }

    private static func classify(_ words: [String], _ start: Int, _ end: Int,
                                 _ tokens: [Token], _ chars: [Character]) -> Conversion? {
        let lastEnd = tokens[end - 1].range.upperBound
        let dollarPrefix = dollarPrefix(tokens[start].range.lowerBound, chars)
        let suffix = end < tokens.count && joined(tokens[end - 1], tokens[end], chars)
            ? tokens[end].word : ""
        func verified(_ text: String, _ kind: ITNKind, _ value: Decimal,
                      _ upper: Int? = nil) -> Conversion? {
            guard verify(text, value: value, kind: kind) else { return nil }
            return Conversion(text: text, kind: kind, end: upper ?? lastEnd, value: value)
        }

        // A version has at least three groups; each group must be an integer
        // or an exact sequence of spoken digits. Preserve zeros in codes.
        if words.filter({ $0 == "point" }).count >= 2 {
            let groups = words.split(separator: "point", omittingEmptySubsequences: false)
            var digits: [String] = []
            for group in groups {
                guard let text = digitGroup(Array(group)) else { return nil }
                digits.append(text)
            }
            let output = digits.joined(separator: ".")
            guard output.split(separator: ".").map(String.init) == digits else { return nil }
            return Conversion(text: output, kind: .version, end: lastEnd)
        }

        let dottedMeridiem = ["a", "p"].contains(suffix) && end + 1 < tokens.count
            && tokens[end + 1].word == "m"
            && String(chars[tokens[end].range.upperBound..<tokens[end + 1].range.lowerBound]) == "."
            && tokens[end + 1].range.upperBound < chars.count && chars[tokens[end + 1].range.upperBound] == "."
        let meridiem = suffix == "am" || suffix == "pm" || dottedMeridiem
        let previous = start > 0 && joined(tokens[start - 1], tokens[start], chars)
            ? tokens[start - 1].word : ""
        let before = String(chars[max(0, tokens[start].range.lowerBound - 8)..<tokens[start].range.lowerBound])
        let cueDistance = before.reversed().prefix(while: \.isWhitespace).count
        let mandarinTime = cueDistance <= 3 && ["早上", "上午", "中午", "下午", "晚上", "凌晨", "傍晚", "半夜", "今晚", "明晚"]
            .contains { before.trimmingCharacters(in: .whitespaces).hasSuffix($0) }
        // "at Twenty One" can be a proper name. Capitalized following nouns
        // also make the at-only reading uncertain ("at nine Fifteen").
        let atCue = previous == "at" && tokens[start].original.first?.isUppercase != true
            && (end == tokens.count || suffix.isEmpty || tokens[end].original.first?.isUppercase != true)
        let explicitNumericForm = words.contains("point")
            || ["percent", "per", "dollar", "dollars", "cent", "cents"].contains(suffix)
        if !explicitNumericForm && (meridiem || atCue || mandarinTime) {
            if let time = clock(words) {
                let output = "\(time.0):" + String(format: "%02d", time.1)
                let sequence = output.split(separator: ":").compactMap { Int($0) }
                guard sequence == [time.0, time.1] else { return nil }
                // Leave the existing am/pm spelling, case and spacing outside
                // the span; those characters are not part of the number.
                return Conversion(text: output, kind: .time, end: lastEnd)
            }
            if meridiem, let hour = Parser.integer(words), (1...12).contains(hour) {
                return verified(String(hour), .time, Decimal(hour))
            }
        }

        let unitOrMoney = measurementUnits.contains(suffix)
            || ["dollar", "dollars", "cent", "cents", "percent", "per"].contains(suffix) || dollarPrefix
        if !unitOrMoney, let year = year(words) { return verified(String(year), .year, Decimal(year)) }

        if let last = words.last, let cardinal = Parser.ordinals[last] {
            var merged = words
            merged[merged.count - 1] = cardinal
            guard let n = Parser.integer(merged), n >= 11 else { return nil }
            return verified(Parser.ordinal(n), .ordinal, Decimal(n))
        }

        if words.count >= 3, (words.count >= 4 || hasDigitCue(start, tokens)), let digits = singleDigits(words) {
            guard digits.count == words.count else { return nil }
            return Conversion(text: digits, kind: .digitString, end: lastEnd)
        }

        guard let number = Parser.number(words) else { return nil }
        let value = number.value
        if suffix == "dollar" || suffix == "dollars" {
            var upper = tokens[end].range.upperBound
            var amount = value
            var centsForm = number.decimal
            if words.first == "a", value >= 1_000_000, moneyTailEnd(end, tokens, chars) == nil,
               let short = roundAmount(number) {
                return verified((dollarPrefix ? "" : "$") + short, .money, value, upper)
            }
            if let centsEnd = moneyTailEnd(end, tokens, chars) {
                guard
                      let cents = Parser.integer(tokens[(end + 2)..<centsEnd].map(\.word)),
                      (0...99).contains(cents), !number.decimal else { return nil }
                amount += Decimal(cents) / 100
                centsForm = true
                upper = tokens[centsEnd].range.upperBound
            }
            guard var money = Parser.money(amount, cents: centsForm) else { return nil }
            if dollarPrefix { money.removeFirst() }
            return verified(money, .money, amount, upper)
        }
        if suffix == "cent" || suffix == "cents" {
            let amount = value / 100
            guard var money = Parser.money(amount, cents: true) else { return nil }
            if dollarPrefix { money.removeFirst() }
            return verified(money, .money, amount,
                            tokens[end].range.upperBound)
        }
        if suffix == "percent" {
            return verified(number.plain + "%", .percent, value, tokens[end].range.upperBound)
        }
        if suffix == "per", end + 1 < tokens.count, tokens[end + 1].word == "cent",
           joined(tokens[end], tokens[end + 1], chars) {
            return verified(number.plain + "%", .percent, value, tokens[end + 1].range.upperBound)
        }
        let after = String(chars[lastEnd..<min(chars.count, lastEnd + 4)])
            .trimmingCharacters(in: .whitespaces)
        let unitContext = measurementUnits.contains(suffix) || after.first == "%" || dollarPrefix
        guard value >= 10 || number.decimal || unitContext else { return nil }
        if value >= 1_000_000, let amount = roundAmount(number) {
            return verified(amount, .amount, value)
        }
        return verified(Parser.grouped(number.plain), number.decimal ? .decimal : (unitContext ? .measure : .count), value)
    }

    private static func singleDigits(_ words: [String]) -> String? {
        var output = ""
        for word in words {
            guard let digit = Parser.units[word], digit < 10 else { return nil }
            output += String(digit)
        }
        return output
    }

    private static func digitGroup(_ words: [String]) -> String? {
        guard !words.isEmpty else { return nil }
        if let digits = singleDigits(words) { return digits }
        return Parser.integer(words).map(String.init)
    }

    private static func clock(_ words: [String]) -> (Int, Int)? {
        guard words.count >= 2, words.count <= 5 else { return nil }
        for split in 1..<words.count {
            guard let hour = Parser.integer(Array(words[..<split])), (1...24).contains(hour) else { continue }
            let tail = Array(words[split...])
            let minute: Int64?
            if tail.count == 2, ["oh", "zero"].contains(tail[0]),
               let digit = Parser.units[tail[1]], digit < 10 { minute = digit }
            else { minute = Parser.integer(tail) }
            let explicitZero = tail.first == "oh" || tail.first == "zero"
            if let minute, (0...59).contains(minute), minute >= 10 || explicitZero {
                return (Int(hour), Int(minute))
            }
        }
        return nil
    }

    private static func year(_ words: [String]) -> Int64? {
        guard words.count >= 2, ["nineteen", "twenty"].contains(words[0]) else { return nil }
        let tail = Array(words.dropFirst())
        let value: Int64?
        if tail.count == 2, tail[0] == "oh", let digit = Parser.units[tail[1]], digit < 10 { value = digit }
        else if let n = Parser.small(tail), n >= 10 { value = n }
        else { value = nil }
        guard let value else { return nil }
        return (words[0] == "nineteen" ? 1900 : 2000) + value
    }

    private static func roundAmount(_ number: Parser.Number) -> String? {
        // Whole thousands of millions (or millions of billions) are exact and
        // readable in the short form; smaller residual counts use full digits.
        let scale: Decimal = number.value >= 1_000_000_000 ? 1_000_000_000 : 1_000_000
        let quotient = number.value / scale
        let text = Parser.decimalString(quotient)
        let decimals = text.split(separator: ".").dropFirst().first?.count ?? 0
        guard decimals <= 3 else { return nil }
        return text + (scale == 1_000_000_000 ? " billion" : " million")
    }

    /// Independent output decoding checks arithmetic after formatting.
    private static func verify(_ output: String, value: Decimal, kind: ITNKind) -> Bool {
        var text = output.replacingOccurrences(of: ",", with: "")
        if text.hasPrefix("$") { text.removeFirst() }
        if text.hasSuffix("%") { text.removeLast() }
        if kind == .ordinal { text.removeLast(2) }
        var multiplier: Decimal = 1
        for (suffix, scale) in [(" billion", Decimal(1_000_000_000)), (" million", Decimal(1_000_000))] {
            if text.hasSuffix(suffix) { text.removeLast(suffix.count); multiplier = scale; break }
        }
        guard !text.isEmpty, text.allSatisfy({ isASCIIDigit($0) || $0 == "." }),
              let parsed = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return false }
        return parsed * multiplier == value
    }

    private static func makeEdit(_ range: Range<Int>, _ replacement: String,
                                 _ kind: ITNKind, _ chars: [Character]) -> ITNEdit {
        ITNEdit(range: range, original: String(chars[range]), replacement: replacement,
                kind: kind, language: .english, note: "en \(kind.rawValue)")
    }

    private static func dollarPrefix(_ lower: Int, _ chars: [Character]) -> Bool {
        String(chars[max(0, lower - 4)..<lower]).trimmingCharacters(in: .whitespaces).last == "$"
    }

    private static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            guard asciiWord(chars[i]) else { i += 1; continue }
            let start = i
            while i < chars.count && asciiWord(chars[i]) { i += 1 }
            let original = String(chars[start..<i])
            tokens.append(Token(word: original.lowercased(), original: original, range: start..<i))
        }
        return tokens
    }

    private static func asciiWord(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || isASCIIDigit(c))
    }

    private static func joined(_ a: Token, _ b: Token, _ chars: [Character]) -> Bool {
        let gap = chars[a.range.upperBound..<b.range.lowerBound]
        return !gap.isEmpty && (gap.allSatisfy(\.isWhitespace) || String(gap) == "-")
    }

    private static func protectedTokens(_ tokens: [Token], _ chars: [Character]) -> Set<Int> {
        var protected = Set<Int>()
        var index = 0
        while index < tokens.count {
            let start = index
            var end = start + 1
            while end < tokens.count,
                  String(chars[tokens[end - 1].range.upperBound..<tokens[end].range.lowerBound]) == "-" {
                end += 1
            }
            if end - start > 1, tokens[start..<end].contains(where: { !Parser.isNumber($0.word) }) {
                protected.formUnion(start..<end)
            }
            index = end
        }
        for start in tokens.indices {
            for phrase in idioms where start + phrase.count <= tokens.count {
                let end = start + phrase.count
                guard tokens[start..<end].map(\.word) == phrase else { continue }
                if (start..<(end - 1)).allSatisfy({ joined(tokens[$0], tokens[$0 + 1], chars) }) {
                    protected.formUnion(start..<end)
                }
            }
        }
        return protected
    }

    private static func touchesExistingNumber(_ start: Int, _ end: Int,
                                               _ tokens: [Token], _ chars: [Character]) -> Bool {
        let lower = tokens[start].range.lowerBound
        let upper = tokens[end - 1].range.upperBound
        if unsafeBoundary(lower..<upper, chars) { return true }
        if start > 0, joined(tokens[start - 1], tokens[start], chars),
           tokens[start - 1].word.contains(where: isASCIIDigit) { return true }
        if start >= 2, tokens[start - 1].word == "point",
           tokens[start - 2].word.contains(where: isASCIIDigit),
           joined(tokens[start - 2], tokens[start - 1], chars),
           joined(tokens[start - 1], tokens[start], chars) { return true }
        if end < tokens.count, joined(tokens[end - 1], tokens[end], chars),
           tokens[end].word.contains(where: isASCIIDigit) { return true }
        return false
    }

    /// Avoid creating a mixed-script number that the Chinese recognizer could
    /// newly consume on the next pass. Whitespace remains a safe boundary.
    private static func unsafeBoundary(_ range: Range<Int>, _ chars: [Character]) -> Bool {
        let lower = range.lowerBound
        let upper = range.upperBound
        if lower > 0 {
            let c = chars[lower - 1]
            if ChineseNumberTables.numerals.contains(c) || c == "點" || c == "点" || c == "負" || c == "负"
                || isASCIIDigit(c) || c == "." || c == ":" || c == "_" || c == "'" { return true }
            if ["+", "-", "負", "负"].contains(c), lower >= 2,
               [".", ":", "%"].contains(chars[lower - 2]) { return true }
        }
        if upper < chars.count {
            let c = chars[upper]
            if ChineseNumberTables.numerals.contains(c) || isASCIIDigit(c) || c == "_" || c == "'" { return true }
            if ScriptDetector.isHan(c), upper + 1 < chars.count,
               ChineseNumberTables.numerals.contains(chars[upper + 1]) || isASCIIDigit(chars[upper + 1])
                || chars[upper + 1] == "點" || chars[upper + 1] == "点" { return true }
            if ["+", "-"].contains(c), upper + 1 < chars.count,
               ChineseNumberTables.numerals.contains(chars[upper + 1]) || isASCIIDigit(chars[upper + 1]) { return true }
            if [".", ":", "%"].contains(c), upper + 1 < chars.count {
                let next = chars[upper + 1]
                if ScriptDetector.isHan(next) || ChineseNumberTables.numerals.contains(next) || isASCIIDigit(next) { return true }
                if ["+", "-", "負", "负"].contains(next), upper + 2 < chars.count,
                   ScriptDetector.isHan(chars[upper + 2]) || isASCIIDigit(chars[upper + 2]) { return true }
            }
        }
        return false
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value, character.unicodeScalars.count == 1 else { return false }
        return (48...57).contains(value)
    }
}
