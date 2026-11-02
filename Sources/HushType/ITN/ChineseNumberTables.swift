import Foundation

enum ChineseNumberTables {
    static let digits: [Character: Int64] = ["零": 0, "〇": 0, "一": 1, "幺": 1, "二": 2, "兩": 2, "两": 2,
        "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    static let small: [Character: Int64] = ["十": 10, "百": 100, "千": 1000]
    static let big: [Character: Int64] = ["萬": 10_000, "万": 10_000, "億": 100_000_000, "亿": 100_000_000]
    static let numerals = Set(digits.keys).union(small.keys).union(big.keys)
    static let starredUnits = words("公斤 公里 公尺 公分 公克 公升 毫升 毫米 吋 度 坪 GB MB TB KB")
    static let units = words("公斤 公里 公尺 公分 公克 公升 毫升 毫米 釐米 厘米 米 克 斤 吋 寸 度 坪 % GB MB TB KB 秒 分鐘 分钟 小時 小时 鐘頭 钟头 歲 岁 倍 成 折 元 塊 块 美金 美元 台幣 台币 臺幣 人民幣 人民币 日圓 日圆 港幣 港币 英尺 英里 英寸 呎 碼 码 磅 盎司 公頃 公顷 平方公尺 平方公里 法郎 歐元 欧元 英鎊 英镑 日元 韓元 韩元 盧比 卢比 比索 披索 新台幣 新臺幣 新台币")
    static let measures = words("個 个 位 名 隻 只 張 张 本 條 条 件 台 臺 輛 辆 架 杯 碗 瓶 盒 箱 包 袋 顆 颗 粒 支 枝 把 間 间 家 所 座 棟 栋 層 层 樓 楼 段 次 回 遍 趟 份 種 种 項 项 頁 页 篇 章 節 节 部 人 列 行 筆 笔 票 屆 届 季 期 版 封 場 场 天 日 週 周 星期 禮拜 礼拜 個月 个月 年 世紀 世纪 年代 例 碟 盤 盘 道 首 輪 轮 局 根 片 戶 户 床 艘 頂 顶 分")
    static let tailUnits = words("塊 块 元 度 米 公尺 公斤 毛")
    static let priceCues = words("要 賣 卖 花 付 收 費 费 租 價 价 共 一共 總共 总共 多少 才 只要")
    static let timeCues = words("早上 上午 中午 下午 晚上 凌晨 傍晚 半夜 清晨 晚間 晚间 深夜 今天 明天 昨天 後天 后天 今晚 明晚")
    static let timeSuffixes = words("半 整 鐘 钟 多 左右 以前 以後 以后 之前 之後 之后 開會 开会 出發 出发 到 至")
    static let degreeOccurrences = words("被 當選 当选 獲 获 入圍 入围 蟬聯 蝉联")
    static let digitSuffixes = words("年 號 号 室 樓 楼 大樓 大楼 地震 連假 连假 事件 路") + measures
    static let digitPrefixes = words("房間 房间 撥 拨 分機 分机 第")
    static let additionalProtectedWords = ["五月天", "九成九", "又一度", "又二度", "又三度", "又四度", "又五度", "七七八八"]
    static let additionalMeasures = ["號", "号", "巷", "弄", "副"]
    static let additionalUnits = ["剛果法郎", "刚果法郎"]
    static let currencies = words("美金 美元 台幣 臺幣 台币 人民幣 人民币 日圓 日圆 日元 港幣 港币 法郎 歐元 欧元 英鎊 英镑 韓元 韩元 盧比 卢比 比索 披索 新台幣 新臺幣 新台币")
    static let approximationPrefixes = words("幾 几 數 数 好幾 好几 上 近 破 約 约")
    // Context-dependent 一點 / 十分 / 萬一 / 千萬 and weekdays are handled
    // by the recognizer so unrelated numeric substrings remain independent.
    static let protectedWords = words("一下 一下子 一些 一起 一定 一直 一樣 一样 一般 一切 一旦 一向 一律 一概 一邊 一边 一致 一再 一同 一會 一会 一會兒 一会儿 一陣 一阵 一陣子 一阵子 一番 一口氣 一口气 一時 一时 一輩子 一辈子 一路 一生 一面 一方面 唯一 統一 统一 一模一樣 一模一样 一五一十 一心一意 獨一無二 独一无二 九死一生 九牛二虎 三心二意 三三兩兩 三三两两 七上八下 亂七八糟 乱七八糟 不三不四 五花八門 五花八门 四面八方 一舉兩得 一举两得 千方百計 千方百计 百分百 十全十美 三國 三国 三星 一共 一點點 一点点 一看 一聽 一听 一想 萬萬 万万 千千萬萬 千千万万 再度 千金 百萬富翁 百万富翁 千萬富翁 千万富翁 十萬火急 十万火急 一千零一夜 三百六十行 百分之百 一二三木頭人 一二三木头人")
    static let protectedByInitial: [Character: [[Character]]] = {
        var table: [Character: [[Character]]] = [:]
        for word in protectedWords + additionalProtectedWords {
            let chars = Array(word)
            if let initial = chars.first { table[initial, default: []].append(chars) }
        }
        return table
    }()
    static let contextProtectInitials = Set("千萬万一十禮礼星週周")

    private static func words(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init).sorted { $0.count > $1.count }
    }
    static func isASCII(_ c: Character) -> Bool { c >= "0" && c <= "9" }
    static func isLatin(_ c: Character) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }
    static func isNumeric(_ c: Character) -> Bool { numerals.contains(c) || isASCII(c) }
}
