import Foundation

/// Strict arithmetic grammar. A failed parse rejects the whole candidate, rather
/// than emitting a plausible prefix of an ambiguous spoken number.
enum EnglishNumberParser {
    static let units: [String: Int64] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19
    ]
    static let tens: [String: Int64] = ["twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    static let scales: [String: Int64] = ["thousand": 1_000, "million": 1_000_000,
        "billion": 1_000_000_000, "trillion": 1_000_000_000_000]
    static let ordinals: [String: String] = [
        "first": "one", "second": "two", "third": "three", "fourth": "four",
        "fifth": "five", "sixth": "six", "seventh": "seven", "eighth": "eight",
        "ninth": "nine", "tenth": "ten", "eleventh": "eleven", "twelfth": "twelve",
        "thirteenth": "thirteen", "fourteenth": "fourteen", "fifteenth": "fifteen",
        "sixteenth": "sixteen", "seventeenth": "seventeen", "eighteenth": "eighteen",
        "nineteenth": "nineteen", "twentieth": "twenty", "thirtieth": "thirty",
        "fortieth": "forty", "fiftieth": "fifty", "sixtieth": "sixty",
        "seventieth": "seventy", "eightieth": "eighty", "ninetieth": "ninety",
        "hundredth": "hundred", "thousandth": "thousand", "millionth": "million", "billionth": "billion"
    ]
    static func isNumber(_ word: String) -> Bool {
        units[word] != nil || tens[word] != nil || scales[word] != nil
            || ordinals[word] != nil || word == "hundred"
    }

    static func small(_ words: [String]) -> Int64? {
        guard !words.isEmpty else { return nil }
        if words.count == 1 { return units[words[0]] ?? tens[words[0]] }
        if words.count == 2, let ten = tens[words[0]], let one = units[words[1]],
           (1...9).contains(one) { return ten + one }
        if words.count >= 2, let one = words[0] == "a" ? 1 : units[words[0]], (1...19).contains(one),
           words[1] == "hundred" {
            if words.count == 2 { return one * 100 }
            var rest = Array(words.dropFirst(2))
            if rest.first == "and" { rest.removeFirst() }
            guard let tail = small(rest), tail > 0, tail < 100 else { return nil }
            return one * 100 + tail
        }
        return nil
    }

    static func integer(_ words: [String]) -> Int64? {
        guard !words.isEmpty, words.count <= 40 else { return nil }
        var total: Int64 = 0
        var group: [String] = []
        var lastScale = Int64.max
        for word in words {
            if let scale = scales[word] {
                let section: Int64? = group == ["a"] ? 1 : small(group)
                guard scale < lastScale, let n = section, n > 0 else { return nil }
                let product = n.multipliedReportingOverflow(by: scale)
                let sum = total.addingReportingOverflow(product.partialValue)
                guard !product.overflow, !sum.overflow else { return nil }
                total = sum.partialValue
                lastScale = scale
                group.removeAll(keepingCapacity: true)
            } else {
                // "one thousand and five", but never a dangling conjunction.
                group.append(word)
            }
        }
        if group.isEmpty { return total > 0 ? total : nil }
        if group.first == "and", total > 0 { group.removeFirst() }
        guard let tail = small(group), total == 0 || tail < lastScale else { return nil }
        let sum = total.addingReportingOverflow(tail)
        return sum.overflow ? nil : sum.partialValue
    }

    struct Number {
        let value: Decimal
        let plain: String
        let decimal: Bool
    }

    static func number(_ words: [String]) -> Number? {
        guard !words.isEmpty else { return nil }
        if let point = words.firstIndex(of: "point") {
            guard point > 0, let whole = integer(Array(words[..<point])) else { return nil }
            var fractionWords = Array(words.dropFirst(point + 1))
            var scale: Int64 = 1
            if let last = fractionWords.last, let multiplier = scales[last] {
                scale = multiplier
                fractionWords.removeLast()
            }
            guard !fractionWords.isEmpty, fractionWords.count <= 12 else { return nil }
            var fraction = ""
            for word in fractionWords {
                guard let digit = units[word], digit < 10 else { return nil }
                fraction += String(digit)
            }
            let plain = "\(whole).\(fraction)"
            guard let value = Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            let scaled = value * Decimal(scale)
            return Number(value: scaled, plain: scale == 1 ? plain : decimalString(scaled), decimal: true)
        }
        guard let n = integer(words) else { return nil }
        return Number(value: Decimal(n), plain: String(n), decimal: false)
    }

    static func decimalString(_ value: Decimal) -> String {
        var value = value
        return NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
    }

    static func grouped(_ plain: String) -> String {
        let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
        guard let integer = parts.first, integer.count >= 5 else { return plain }
        var out = ""
        for (index, digit) in integer.enumerated() {
            if index > 0 && (integer.count - index) % 3 == 0 { out += "," }
            out.append(digit)
        }
        if parts.count == 2 { out += "." + parts[1] }
        return out
    }

    static func ordinal(_ n: Int64) -> String {
        let suffix: String
        if (11...13).contains(n % 100) { suffix = "th" }
        else { suffix = [1: "st", 2: "nd", 3: "rd"][Int(n % 10)] ?? "th" }
        return String(n) + suffix
    }

    static func money(_ value: Decimal, cents: Bool = false) -> String? {
        let parts = decimalString(value).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 2 else { return nil }
        var text = String(parts[0])
        if cents || !fraction.isEmpty {
            text += "." + fraction + String(repeating: "0", count: 2 - fraction.count)
        }
        return "$" + grouped(text)
    }
}
