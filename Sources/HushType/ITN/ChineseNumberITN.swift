import Foundation

enum ChineseNumberITN {
    private typealias T = ChineseNumberTables
    private typealias P = ChineseNumberParser

    private struct Span {
        let start: Int
        var end: Int
        let groups: [String]
        let negative: Bool
        let percent: Bool
        let trailingPoint: Bool
        let tailUnit: String?
        let tailDigit: String?
        var unsafeTail = false
        var quarter = false
        var protected = false
        var smallMoney = false
        var value: Decimal?
        var replacement: String?
        var kind: ITNKind = .count
    }

    /// All indices and slices use Character offsets, clamped at the read site.
    static func edits(in chars: [Character]) -> [ITNEdit] {
        let protected = protectedRanges(chars)
        var spans = find(chars)
        for i in spans.indices {
            classify(&spans[i], chars: chars, protected: protected)
        }
        if spans.count >= 2 {
            for i in 0..<(spans.count - 1) {
                // Money tails include their unit in the span, while ordinary
                // amounts leave it outside. Compare both at the unit boundary.
                if let leftEnd = moneyEnd(spans[i], chars), moneyEnd(spans[i + 1], chars) != nil,
                   ["到", "至", "~", "～"].contains(slice(chars, leftEnd, spans[i + 1].start)),
                   !spans[i].protected, !spans[i + 1].protected,
                   spans[i].replacement != nil || spans[i + 1].replacement != nil {
                    for j in [i, i + 1] where spans[j].replacement == nil && spans[j].smallMoney {
                        guard let value = spans[j].value else { continue }
                        spans[j].replacement = NumberFormatPolicy.chinese(value, source: slice(chars, spans[j].start, spans[j].end))
                        spans[j].kind = .money
                    }
                }
                let gap = slice(chars, spans[i].end, spans[i + 1].start)
                guard ["到", "至", "比", "~", "～"].contains(gap),
                      !spans[i].protected, !spans[i + 1].protected,
                      spans[i].groups.count == 1, spans[i + 1].groups.count == 1,
                      !spans[i].trailingPoint, !spans[i + 1].trailingPoint,
                      spans[i].tailUnit == nil, spans[i + 1].tailUnit == nil,
                      let a = P.integer(spans[i].groups[0]), let b = P.integer(spans[i + 1].groups[0]),
                      gap == "比" || spans[i].replacement != nil || spans[i + 1].replacement != nil else { continue }
                for (j, v) in [(i, a), (i + 1, b)] where spans[j].replacement == nil {
                    let value = Decimal(v) * (spans[j].negative ? -1 : 1)
                    spans[j].value = value
                    spans[j].replacement = NumberFormatPolicy.chinese(value, source: slice(chars, spans[j].start, spans[j].end))
                    spans[j].kind = .rangeOrScore
                }
            }
        }
        return spans.compactMap { span in
            guard let out = span.replacement, verify(span, output: out) else { return nil }
            let original = slice(chars, span.start, span.end)
            guard original != out else { return nil }
            return ITNEdit(range: span.start..<span.end, original: original, replacement: out,
                           kind: span.kind, language: .chinese, note: span.kind.rawValue)
        }
    }

    private static func find(_ chars: [Character]) -> [Span] {
        var spans: [Span] = []
        var i = 0
        while i < chars.count {
            // Weekday numerals are a fixed-word boundary, even with no space
            // before the hour (星期三兩點). Do not absorb them into that hour.
            if "一二三四五六日天".contains(chars[i]),
               ["禮拜", "礼拜", "星期", "週", "周"].contains(where: slice(chars, i - 2, i).hasSuffix) {
                i += 1
                continue
            }
            var j = i
            var negative = false
            if chars[j] == "負" || chars[j] == "负" { negative = true; j += 1 }
            let percent = starts(chars, j, "百分之")
            if percent { j += 3 }
            guard j < chars.count, T.isNumeric(chars[j]) else { i += 1; continue }
            let coreStart = j
            var unsafeTail = false
            var groups: [String] = []
            repeat {
                let start = j
                while j < chars.count && T.isNumeric(chars[j]) { j += 1 }
                groups.append(slice(chars, start, j))
                if j + 1 < chars.count && isPoint(chars[j]) && T.isNumeric(chars[j + 1]) { j += 1 }
                else { break }
            } while j < chars.count
            // A following article is not an abbreviated magnitude digit.
            // 三萬一個月 is 三萬 + 一個月, not 三萬一 + 個月.
            if groups.count == 1, j >= coreStart + 3,
               T.big[chars[j - 2]] != nil, (T.digits[chars[j - 1]] ?? Int64(String(chars[j - 1])) ?? 0) > 0,
               !tailBoundary(chars, j) {
                if matching(T.measures + T.additionalMeasures, chars, j) != nil {
                    j -= 1
                    groups[0].removeLast()
                } else {
                    unsafeTail = true
                }
            }
            let trailingPoint = j < chars.count && isPoint(chars[j])
            if trailingPoint { j += 1 }
            // A Han verb ending in 負 is outside the numeric span, except for
            // an unambiguous percent/decimal sign.
            if negative && i > 0 && ScriptDetector.isHan(chars[i - 1]) {
                let lexical = "欺勝胜抱辜自擔担背正".contains(chars[i - 1])
                let unambiguous = percent || groups.count >= 2 || starts(chars, j, "度")
                if lexical || !unambiguous {
                    i += 1
                    continue
                }
            }
            var tailUnit: String?
            var tailDigit: String?
            if groups.count == 1 && !trailingPoint,
               let unit = matching(T.tailUnits, chars, j) {
                let d = j + unit.count
                if d < chars.count && (T.digits[chars[d]] != nil || T.isASCII(chars[d])),
                   tailBoundary(chars, d + 1) || matching(T.measures + T.additionalMeasures, chars, d + 1) == nil {
                    unsafeTail = unsafeTail || !tailBoundary(chars, d + 1)
                    tailUnit = unit
                    tailDigit = String(chars[d])
                    j = d + 1
                    if ["塊", "块", "元"].contains(unit), j < chars.count && (chars[j] == "毛" || chars[j] == "角") {
                        j += 1
                    }
                }
            }
            // ASCII-only spans are already formatted. Mixed ASR spans are
            // forbidden inside Latin identifiers, decimals and clock times.
            let source = slice(chars, coreStart, j)
            let mixed = source.contains(where: T.isASCII)
            let blocked = mixed && i > 0 && (T.isLatin(chars[i - 1]) || chars[i - 1] == "." || chars[i - 1] == ":")
            if !blocked && source.contains(where: { T.numerals.contains($0) }) {
                spans.append(Span(start: i, end: j, groups: groups, negative: negative, percent: percent,
                                  trailingPoint: trailingPoint, tailUnit: tailUnit, tailDigit: tailDigit, unsafeTail: unsafeTail))
            }
            i = max(j, i + 1)
        }
        return spans
    }

    private static func classify(_ s: inout Span, chars: [Character], protected: [Range<Int>]) {
        let before = slice(chars, s.start - 12, s.start)
        var after = slice(chars, s.end, s.end + 12)
        let source = slice(chars, s.start, s.end)
        let core = s.groups[0]
        func protect(_ s: inout Span) { s.protected = true }
        if s.unsafeTail { protect(&s); return }
        if protected.contains(where: { $0.overlaps(s.start..<s.end) }) { protect(&s); return }
        if core == "二百五" && ["個", "个", "是", "真", "很"].contains(where: before.hasSuffix) { protect(&s); return }
        if s.groups.count == 1 && !s.trailingPoint && core.first.map({ T.small[$0] != nil || T.big[$0] != nil }) == true &&
            T.approximationPrefixes.contains(where: before.hasSuffix) { protect(&s); return }
        // Glued bilingual numeral fragments are uncertain. In particular, a
        // unit-tail rewrite must not expose an English word to a later pass.
        if adjacentLatinNumber(chars, start: s.start, end: s.end) { protect(&s); return }
        // An adjacent 負 is a word/sign boundary that depends on the preceding
        // script. Retain that context rather than enabling a sign on a rerun.
        if after.hasPrefix("負") || after.hasPrefix("负") { protect(&s); return }
        if ["幾", "几", "來", "来", "餘", "余", "分之"].contains(where: after.hasPrefix) ||
            (after.hasPrefix("多") && s.groups.count == 1 && !s.trailingPoint && (P.integer(core) ?? 0) < 100) {
            protect(&s); return
        }
        // Never convert the denominator of a kept fraction either.
        if before.hasSuffix("分之") { protect(&s); return }
        if before.hasSuffix("第") && (after.hasPrefix("度")) { protect(&s); return }
        let cue = hasTimeCue(before) || bareHourPairBefore(chars, s.start)

        if s.groups.count >= 3 {
            guard !s.negative, !s.percent, !s.trailingPoint, s.tailUnit == nil else { protect(&s); return }
            let values = s.groups.compactMap(groupDigits)
            guard values.count == s.groups.count else { protect(&s); return }
            s.replacement = values.joined(separator: ".")
            s.kind = .version
            return
        }
        if s.groups.count == 2 {
            guard !s.trailingPoint, s.tailUnit == nil, let whole = P.integer(core) else { protect(&s); return }
            let tail = s.groups[1]
            if after.hasPrefix("刻") {
                guard !s.negative, !s.percent, whole <= 24, let quarter = P.integer(tail), quarter == 1 || quarter == 3 else { protect(&s); return }
                s.end += after.hasPrefix("刻鐘") || after.hasPrefix("刻钟") ? 2 : 1
                s.quarter = true
                s.replacement = String(whole) + ":" + String(quarter * 15)
                s.kind = .time
                return
            }
            let hasMinute = after.hasPrefix("分")
            if after.hasPrefix("分鐘") || after.hasPrefix("分钟") { protect(&s); return }
            let time = !s.percent && !s.negative && (cue || hasMinute || T.timeSuffixes.contains(where: after.hasPrefix))
            if time {
                let minutes = minuteValue(tail)
                guard whole <= 24, let minutes, minutes < 60 else { protect(&s); return }
                if hasMinute { s.end += 1 }
                s.replacement = String(whole) + ":" + (minutes < 10 ? "0" : "") + String(minutes)
                s.kind = .time
                return
            }
            // Decimal fractions are digit sequences, optionally followed by
            // one big unit (三點五萬); positional tails such as 三點十五 stay.
            var fraction = tail
            var scale: Decimal = 1
            if let last = fraction.last, let big = T.big[last] { scale = Decimal(big); fraction.removeLast() }
            guard let digits = P.digitString(fraction), digits.count <= 16,
                  let number = Decimal(string: String(whole) + "." + digits, locale: Locale(identifier: "en_US_POSIX")) else { protect(&s); return }
            let value = number * scale * (s.negative ? -1 : 1)
            s.value = value
            s.replacement = scale == 1 ? (s.negative ? "-" : "") + String(whole) + "." + digits : NumberFormatPolicy.chinese(value, source: source)
            if s.percent { s.replacement = s.replacement.map { $0 + "%" } }
            s.kind = s.percent ? .percent : .decimal
            return
        }
        let measure = matching(T.measures + T.additionalMeasures, chars, s.end)
        let directToken = String(chars[..<s.start].reversed().prefix(while: { T.isLatin($0) || T.isASCII($0) }).reversed())
        let betweenLatin = directToken.last.map(T.isLatin) == true && after.first.map(T.isLatin) == true &&
            matching(T.units + T.additionalUnits, chars, s.end) == nil
        let modelSuffix = betweenLatin && allowsLatinSuffix(token: directToken, core: core, after: after)
        // Clock/decimal handling keeps priority over model-code suffixes.
        if betweenLatin && !s.trailingPoint && s.tailUnit == nil && !modelSuffix { protect(&s); return }
        if let digits = P.digitString(core), core.count >= 3 || modelSuffix && core.count >= 2 {
            let allowed = modelSuffix || core.count >= 4 || matching(T.digitSuffixes, chars, s.end) != nil || T.digitPrefixes.contains(where: before.hasSuffix)
            guard allowed, !s.percent, !s.negative, !s.trailingPoint, s.tailUnit == nil else { protect(&s); return }
            s.replacement = digits
            s.kind = after.hasPrefix("年") ? .year : .digitString
            return
        }
        guard let int = P.integer(core) else { protect(&s); return }
        let value = Decimal(int) * (s.negative ? -1 : 1)
        s.value = value
        if let unit = s.tailUnit, let tail = s.tailDigit, let digits = P.digitString(tail),
           let number = Decimal(string: String(int) + "." + digits, locale: Locale(identifier: "en_US_POSIX")) {
            if unit == "度" && T.degreeOccurrences.contains(where: after.hasPrefix) { protect(&s); return }
            s.value = number * (s.negative ? -1 : 1)
            s.replacement = (s.negative ? "-" : "") + String(int) + "." + digits + unit
            s.kind = unit == "塊" || unit == "块" || unit == "元" || unit == "毛" ? .money : .measure
            return
        }
        if s.percent {
            s.replacement = NumberFormatPolicy.plain(value) + "%"
            s.kind = .percent
            return
        }
        if s.trailingPoint {
            guard int <= 24, !s.negative, cue || T.timeSuffixes.contains(where: after.hasPrefix) else { protect(&s); return }
            if after.hasPrefix("半") {
                s.end += 1
                s.replacement = String(int) + ":30"
            } else {
                s.replacement = String(int) + String(source.last!)
            }
            s.kind = .time
            return
        }
        if before.hasSuffix("第") {
            if int > 10 { s.replacement = String(int); s.kind = .ordinal }
            else { protect(&s) }
            return
        }
        if core.count == 1 && core != "十" && (T.small[core.first!] != nil || T.big[core.first!] != nil) {
            protect(&s); return
        }
        if after.hasPrefix("月"), (1...12).contains(int) {
            s.replacement = String(int); s.kind = .date; return
        }
        if (after.hasPrefix("號") || after.hasPrefix("号") || after.hasPrefix("日")), (1...31).contains(int),
           monthImmediatelyBefore(chars, s.start) {
            s.replacement = String(int); s.kind = .date; return
        }
        if addressChainBefore(chars, s.start) {
            if after.hasPrefix("段") { protect(&s); return }
            if ["號", "号", "巷", "弄", "樓", "楼"].contains(where: after.hasPrefix) {
                s.replacement = String(int); s.kind = .count; return
            }
        }
        // A following measure uses the ordinary count rules, even when the
        // product name and count are glued together (iPad一臺 / Pixel十個).
        if measure == nil, let last = before.last, T.isLatin(last) {
            if directToken.contains(where: T.isASCII) {
                guard int != 1 else { protect(&s); return }
            }
            s.replacement = String(int); s.kind = .modelCode; return
        }
        if before.hasSuffix(" ") {
            let token = before.dropLast().reversed().prefix(while: { T.isLatin($0) || T.isASCII($0) }).reversed()
            if token.contains(where: T.isLatin) && token.contains(where: { ($0 >= "A" && $0 <= "Z") || T.isASCII($0) }) {
                guard measure == nil, int != 1 else { protect(&s); return }
                s.replacement = String(int); s.kind = .modelCode; return
            }
        }
        if after.hasPrefix("度") && int < 10 && T.degreeOccurrences.contains(where: { after.dropFirst().hasPrefix($0) }) {
            protect(&s); return
        }
        if after.hasPrefix("度") && int < 10 && (before.hasSuffix("負") || before.hasSuffix("负")) {
            if before.dropLast().last.map({ "欺勝胜抱辜自擔担背正".contains($0) }) == true { protect(&s); return }
        }
        if let unit = matching(T.units + T.additionalUnits, chars, s.end) {
            if unit == "塊" || unit == "块" {
                if matching(T.currencies, chars, s.end + unit.count) != nil {
                    s.replacement = NumberFormatPolicy.chinese(value, source: source)
                    s.kind = .money
                    return
                }
                let money = after.dropFirst().hasPrefix("錢") || after.dropFirst().hasPrefix("钱") ||
                    T.priceCues.contains(where: { slice(chars, s.start - 6, s.start).contains($0) })
                guard int >= 10 || (int >= 2 && money) else { s.smallMoney = true; return }
            } else if int < 2 && !(int == 1 && T.starredUnits.contains(unit)) {
                if unit == "元" { s.smallMoney = true } else { protect(&s) }
                return
            }
            s.replacement = NumberFormatPolicy.chinese(value, source: source)
            s.kind = int >= 10_000 ? .amount : .measure
            return
        }
        if measure != nil {
            guard int >= 10 else { return }
            s.replacement = NumberFormatPolicy.chinese(value, source: source)
            s.kind = int >= 10_000 ? .amount : .count
            return
        }
        if before.hasSuffix("今年") || after.hasPrefix("出頭") || after.hasPrefix("出头") {
            s.replacement = NumberFormatPolicy.chinese(value, source: source); return
        }
        if core.contains(where: { T.big[$0] != nil }) {
            guard core.first.map({ T.digits[$0] != nil || T.isASCII($0) || $0 == "十" }) == true else { protect(&s); return }
            s.replacement = NumberFormatPolicy.chinese(value, source: source)
            s.kind = .amount
            return
        }
        after = slice(chars, s.end, s.end + 3)
        let bareAllowed = after.isEmpty || after.first.map { !ScriptDetector.isHan($0) } == true ||
            ["的", "左右", "多", "以上", "以下", "上下", "吧", "了", "到", "至", "不", "也", "就", "都", "還", "还", "才", "而已"].contains(where: after.hasPrefix)
        if int >= 100 && bareAllowed {
            s.replacement = NumberFormatPolicy.chinese(value, source: source)
            s.kind = int >= 10_000 ? .amount : .count
        }
    }

    private static func verify(_ s: Span, output: String) -> Bool {
        guard !output.contains(where: { ITNMerge.chineseNumeralCharacters.contains($0) || $0 == "幺" }) else { return false }
        if s.kind == .version {
            return output.components(separatedBy: ".") == s.groups.compactMap(groupDigits)
        }
        if s.kind == .digitString || s.kind == .year { return P.digitString(s.groups[0]) == output }
        if s.kind == .time {
            guard let hour = P.integer(s.groups[0]), hour <= 24 else { return false }
            if output.contains(":") {
                let pieces = output.components(separatedBy: ":")
                let minutes = s.quarter ? P.integer(s.groups[1]).map { $0 * 15 } : (s.groups.count == 2 ? minuteValue(s.groups[1]) : 30)
                return pieces.count == 2 && Int64(pieces[0]) == hour && Int64(pieces[1]) == minutes
            }
            return output == String(hour) + (s.trailingPoint ? "點" : "")
                || output == String(hour) + "点"
        }
        var numeric = output
        if let unit = s.tailUnit, numeric.hasSuffix(unit) { numeric.removeLast(unit.count) }
        guard let expected = s.value, let actual = P.outputValue(numeric) else { return false }
        return expected == actual
    }

    private static func groupDigits(_ group: String) -> String? {
        P.digitString(group) ?? P.integer(group).map(String.init)
    }
    private static func allowsLatinSuffix(token: String, core: String, after: String) -> Bool {
        let uppercaseCode = (1...4).contains(token.count) && token.allSatisfy { $0 >= "A" && $0 <= "Z" }
        let uppercaseFollower = after.first.map { $0 >= "A" && $0 <= "Z" } == true
        return uppercaseCode || uppercaseFollower && ((P.integer(core) ?? 0) >= 10 || P.digitString(core) != nil)
    }
    private static func minuteValue(_ group: String) -> Int64? {
        if let digits = P.digitString(group) { return digits.count <= 2 ? Int64(digits) : nil }
        return P.integer(group)
    }
    private static func monthImmediatelyBefore(_ chars: [Character], _ pos: Int) -> Bool {
        guard pos > 0, chars[pos - 1] == "月" else { return false }
        var i = pos - 1
        while i > 0 && T.isNumeric(chars[i - 1]) { i -= 1 }
        let month = slice(chars, i, pos - 1)
        guard let n = P.integer(month) ?? P.digitString(month).flatMap(Int64.init) else { return false }
        return (1...12).contains(n)
    }
    private static func weekdaySuffix(_ text: String) -> Bool {
        guard let last = text.last, "一二三四五六日天1234567".contains(last) else { return false }
        let prefix = text.dropLast()
        return ["禮拜", "礼拜", "星期", "週", "周"].contains(where: prefix.hasSuffix)
    }
    private static func hasTimeCue(_ before: String) -> Bool {
        (0...min(3, before.count)).contains { gap in
            let prefix = String(before.dropLast(gap))
            return T.timeCues.contains(where: prefix.hasSuffix) || weekdaySuffix(prefix)
        }
    }
    private static func tailBoundary(_ chars: [Character], _ pos: Int) -> Bool {
        guard pos < chars.count else { return true }
        guard pos >= 0 else { return false }
        let c = chars[pos]
        if !ScriptDetector.isHan(c) { return !T.isNumeric(c) }
        return matching(T.units + T.additionalUnits + T.currencies + ["錢", "钱", "毛", "角", "吧", "了", "啊", "喔", "而已", "左右", "多", "和", "跟", "或", "與", "与", "及", "到", "至", "比", "～", "~", "之間", "之间", "以上", "以下", "以內", "以内", "的"], chars, pos) != nil
    }
    private static func moneyEnd(_ span: Span, _ chars: [Character]) -> Int? {
        if let unit = span.tailUnit, ["塊", "块", "元"].contains(unit) {
            return tailBoundary(chars, span.end) ? span.end : nil
        }
        guard let unit = matching(["塊", "块", "元"], chars, span.end),
              tailBoundary(chars, span.end + unit.count) else { return nil }
        return span.end + unit.count
    }
    private static func bareHourPairBefore(_ chars: [Character], _ start: Int) -> Bool {
        guard start >= 3, ["到", "至"].contains(chars[start - 1]), isPoint(chars[start - 2]) else { return false }
        var lower = start - 2
        while lower > 0 && T.isNumeric(chars[lower - 1]) { lower -= 1 }
        guard let hour = P.integer(slice(chars, lower, start - 2)) else { return false }
        return hour <= 24
    }
    private static func addressChainBefore(_ chars: [Character], _ start: Int) -> Bool {
        let local = slice(chars, start - 24, start)
        let chain = local.reversed().prefix(while: { !$0.isWhitespace && !"，。！？,!?;；".contains($0) })
        return chain.contains(where: { "路街段巷弄".contains($0) })
    }
    private static func adjacentLatinNumber(_ chars: [Character], start: Int, end: Int) -> Bool {
        var a = start
        while a > 0 && T.isLatin(chars[a - 1]) { a -= 1 }
        var b = end
        while b < chars.count && T.isLatin(chars[b]) { b += 1 }
        return EnglishNumberParser.isNumber(slice(chars, a, start).lowercased()) ||
            EnglishNumberParser.isNumber(slice(chars, end, b).lowercased())
    }
    private static func protectedRanges(_ chars: [Character]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for i in chars.indices {
            for word in T.protectedByInitial[chars[i]] ?? [] {
                if word.count <= chars.count - i && chars[i..<(i + word.count)].elementsEqual(word) {
                    result.append(i..<(i + word.count))
                }
            }
            guard T.contextProtectInitials.contains(chars[i]) else { continue }
            let before = slice(chars, i - 2, i)
            let after = slice(chars, i, i + 10)
            if (after.hasPrefix("千萬") || after.hasPrefix("千万")) && (i == 0 || !T.isNumeric(chars[i - 1])) &&
                ["不", "別", "别", "要", "記", "记", "小心", "注意", "拜託", "拜托", "保重"].contains(where: { after.dropFirst(2).hasPrefix($0) }) {
                result.append(i..<(i + 2))
            }
            if (after.hasPrefix("萬一") || after.hasPrefix("万一")) &&
                (i == 0 || !T.isNumeric(chars[i - 1])) &&
                (i + 2 >= chars.count || T.small[chars[i + 2]] == nil) { result.append(i..<(i + 2)) }
            if (after.hasPrefix("一點") || after.hasPrefix("一点")) &&
                (i == 0 || !T.isNumeric(chars[i - 1])) &&
                !["午", "上", "晚", "晨", "點", "点"].contains(where: before.hasSuffix) &&
                !hasTimeCue(slice(chars, i - 8, i)) && !bareHourPairBefore(chars, i) &&
                !T.timeSuffixes.contains(where: slice(chars, i + 2, i + 6).hasPrefix) &&
                (i + 2 >= chars.count || !"半零〇一二三四五六七八九十分鐘钟".contains(chars[i + 2])) {
                result.append(i..<(i + 2))
            }
            if after.hasPrefix("十分") && (i == 0 || !T.isNumeric(chars[i - 1]) && !isPoint(chars[i - 1])) &&
                (i + 2 >= chars.count || !"鐘钟".contains(chars[i + 2])) { result.append(i..<(i + 2)) }
            for cue in ["禮拜", "礼拜", "星期", "週", "周"] where starts(chars, i, cue) {
                let j = i + cue.count
                if j < chars.count && "一二三四五六日天".contains(chars[j]) { result.append(i..<(j + 1)) }
            }
        }
        return result
    }
    private static func isPoint(_ c: Character) -> Bool { c == "點" || c == "点" }
    private static func matching(_ words: [String], _ chars: [Character], _ pos: Int) -> String? {
        words.first(where: { starts(chars, pos, $0) })
    }
    private static func starts(_ chars: [Character], _ pos: Int, _ word: String) -> Bool {
        guard pos >= 0, pos <= chars.count, word.count <= chars.count - pos else { return false }
        return chars[pos..<(pos + word.count)].elementsEqual(word)
    }
    private static func slice(_ chars: [Character], _ start: Int, _ end: Int) -> String {
        let a = min(chars.count, max(0, start))
        let b = min(chars.count, max(a, end))
        return String(chars[a..<b])
    }
}
