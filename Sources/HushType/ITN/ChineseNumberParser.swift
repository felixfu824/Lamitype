import Foundation

/// Strict parsing: ambiguous runs and malformed unit orders fail atomically.
enum ChineseNumberParser {
    private typealias T = ChineseNumberTables

    static func digitString(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var result = ""
        for c in text {
            if let d = T.digits[c] { result += String(d) }
            else if T.isASCII(c) { result.append(c) }
            else { return nil }
        }
        return result
    }

    static func integer(_ text: String) -> Int64? {
        let chars = Array(text)
        guard !chars.isEmpty, !chars.contains("幺") else { return nil }
        var total: Int64 = 0
        var start = 0
        var lastBig = Int64.max
        var finalBig: Int64?
        var singleBeforeBig = false
        for i in chars.indices {
            guard let big = T.big[chars[i]] else { continue }
            guard big < lastBig, i > start,
                  let section = section(Array(chars[start..<i])), section > 0,
                  let multiplied = multiply(section, big), let added = add(total, multiplied) else { return nil }
            total = added
            lastBig = big
            finalBig = big
            singleBeforeBig = i - start == 1 && (T.digits[chars[start]] != nil || T.isASCII(chars[start]))
            start = i + 1
        }
        if start == chars.count { return total }
        let tail = Array(chars[start..<chars.count])
        if finalBig != nil && tail.count == 1 && (tail[0] == "零" || tail[0] == "〇") { return nil }
        guard var value = section(tail) else { return nil }
        if finalBig != nil && tail.count > 1 && value < 1000 && tail[0] != "零" && tail[0] != "〇" {
            return nil
        }
        if let big = finalBig, tail.count == 1, let digit = T.digits[tail[0]] ?? Int64(String(tail[0])), digit > 0 {
            guard singleBeforeBig, let scaled = multiply(value, big / 10) else { return nil }
            value = scaled
        }
        if finalBig != nil && value >= lastBig { return nil }
        return add(total, value)
    }

    private static func section(_ chars: [Character]) -> Int64? {
        guard !chars.isEmpty else { return nil }
        if chars.allSatisfy(T.isASCII) { return Int64(String(chars)) }
        if chars.count == 1, let d = T.digits[chars[0]] { return d }
        if chars.count == 2, chars[0] == "零" || chars[0] == "〇", let d = T.digits[chars[1]] { return d }
        var value: Int64 = 0
        var pending: Int64?
        var lastUnit: Int64 = 10_000
        var sawUnit = false
        var zero = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "零" || c == "〇" {
                guard pending == nil, !zero else { return nil }
                zero = true
                i += 1
            } else if let d = T.digits[c], d > 0 {
                guard pending == nil else { return nil }
                pending = d
                i += 1
            } else if T.isASCII(c) {
                guard pending == nil else { return nil }
                let start = i
                while i < chars.count && T.isASCII(chars[i]) { i += 1 }
                guard let d = Int64(String(chars[start..<i])) else { return nil }
                pending = d
            } else if let unit = T.small[c] {
                guard unit < lastUnit, (!zero || pending != nil),
                      pending != nil || (!sawUnit && value == 0),
                      let product = multiply(pending ?? 1, unit), let added = add(value, product) else { return nil }
                value = added
                pending = nil
                lastUnit = unit
                sawUnit = true
                zero = false
                i += 1
            } else { return nil }
        }
        guard sawUnit, !zero || pending != nil else { return nil }
        if let pending {
            let factor = !zero && lastUnit >= 10 ? lastUnit / 10 : 1
            guard let product = multiply(pending, factor), let added = add(value, product) else { return nil }
            value = added
        }
        return value
    }

    private static func multiply(_ a: Int64, _ b: Int64) -> Int64? {
        let r = a.multipliedReportingOverflow(by: b)
        return r.overflow ? nil : r.partialValue
    }
    private static func add(_ a: Int64, _ b: Int64) -> Int64? {
        let r = a.addingReportingOverflow(b)
        return r.overflow ? nil : r.partialValue
    }

    /// Output grammar is parsed independently of Chinese input parsing.
    static func outputValue(_ output: String) -> Decimal? {
        var value = output
        if value.last == "%" { value.removeLast() }
        var scale: Decimal = 1
        if let last = value.last, let big = T.big[last] { scale = Decimal(big); value.removeLast() }
        guard !value.isEmpty, value.filter({ $0 == "." }).count <= 1,
              value.enumerated().allSatisfy({ T.isASCII($0.element) || $0.element == "." || ($0.offset == 0 && $0.element == "-") }),
              let parsed = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return parsed * scale
    }
}
