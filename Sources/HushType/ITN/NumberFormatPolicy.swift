import Foundation

enum NumberFormatPolicy {
    static func plain(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    static func chinese(_ value: Decimal, source: String) -> String? {
        let magnitude = value < 0 ? -value : value
        guard magnitude >= 10_000 else { return plain(value) }
        let yi = source.last(where: { $0 == "億" || $0 == "亿" })
        let wan = source.last(where: { $0 == "萬" || $0 == "万" })
        let scale: Decimal = magnitude >= 100_000_000 ? 100_000_000 : 10_000
        let unit = scale == 100_000_000 ? (yi ?? (wan == "万" ? "亿" : "億")) : (wan ?? (yi == "亿" ? "万" : "萬"))
        let divided = value / scale
        var rounded = Decimal()
        var copy = divided
        NSDecimalRound(&rounded, &copy, scale == 10_000 ? 2 : 4, .plain)
        if rounded != divided {
            return scale == 10_000 ? plain(value) : nil
        }
        return plain(divided) + String(unit)
    }

    static func englishGrouped(_ value: Int64) -> String {
        let digits = String(value.magnitude)
        guard value.magnitude >= 10_000 else { return String(value) }
        let chars = Array(digits)
        let grouped = chars.indices.map { i in
            (i > 0 && (chars.count - i).isMultiple(of: 3) ? "," : "") + String(chars[i])
        }.joined()
        return (value < 0 ? "-" : "") + grouped
    }

    static func ordinalSuffix(_ value: Int64) -> String {
        let n = value.magnitude
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }
}
