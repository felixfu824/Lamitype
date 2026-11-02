import XCTest
@testable import HushType

final class ChineseNumberITNTests: XCTestCase {
    // Mirrors are deterministic test data, independent of installed OpenCC.
    private func simplified(_ text: String) -> String {
        let trad = Array("剛盤輪戶頂碼頃歐鎊韓盧當買個點號兩萬億負塊錢歲間撥機樓顆項頁節場隻張條輛棟層種筆屆週禮時鐘頭幣圓釐臺獲選圍蟬聯勝體開會講後寫蘋書預應該對這國邊樣陣聽獨舉亂門統輩氣時模託記別連假木頭積電製訂")
        let simp = Array("刚盘轮户顶码顷欧镑韩卢当买个点号两万亿负块钱岁间拨机楼颗项页节场只张条辆栋层种笔届周礼时钟头币圆厘台获选围蝉联胜体开会讲后写苹书预应该对这国边样阵听独举乱门统辈气时模托记别连假木头积电制订")
        let map = Dictionary(zip(trad, simp), uniquingKeysWith: { a, _ in a })
        return String(text.map { map[$0] ?? $0 })
    }

    private func check(_ pairs: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        for (input, expected) in pairs {
            for (source, target) in [(input, expected), (simplified(input), simplified(expected))] {
                let chars = Array(source)
                let edits = ChineseNumberITN.edits(in: chars)
                XCTAssertEqual(ITNMerge.validEdits(edits, in: chars), edits, source, file: file, line: line)
                let actual = ITNMerge.apply(edits, to: chars)
                XCTAssertEqual(actual, target, source, file: file, line: line)
                let twice = ITNMerge.apply(ChineseNumberITN.edits(in: Array(actual)), to: Array(actual))
                XCTAssertEqual(twice, actual, "idempotence: \(source)", file: file, line: line)
                var last = 0
                for edit in edits {
                    XCTAssertGreaterThanOrEqual(edit.range.lowerBound, last, source, file: file, line: line)
                    XCTAssertEqual(edit.original, String(chars[edit.range]), source, file: file, line: line)
                    last = edit.range.upperBound
                }
            }
        }
    }

    func testEveryShippingDefectSection2a() {
        check([
            ("好", "好"), ("", ""), ("一一七名", "117名"), ("一一七", "一一七"),
            ("五六", "五六"), ("三四", "三四"), ("七八十", "七八十"), ("五六百萬", "五六百萬"),
            ("我一定要買十二個", "我一定要買12個"), ("一個人", "一個人"), ("千萬不要", "千萬不要"),
            ("零點五點十六", "0.5.16"), ("十月二十九號", "10月29號"), ("二〇二六年", "2026年"),
            ("三萬五", "3.5萬"), ("七點五十分", "7:50"), ("兩萬五千塊", "2.5萬塊")
        ])
        // English defect is covered through the facade rather than the Chinese recognizer.
        XCTAssertEqual(NumberNormalizer.normalize("forty-five thousand dollars").text, "$45,000")
    }

    func testEveryPrototypeDefectSection2b() {
        check([
            ("欺負十二個人", "欺負12個人"), ("勝負一百場", "勝負100場"), ("兩千五萬", "2500萬"),
            ("三塊八", "3.8塊"), ("三十八度五", "38.5度"),
            ("我買了 iPad 一台", "我買了 iPad 一台"), ("寫 email 兩封", "寫 email 兩封"),
            ("下午兩點零五", "下午2:05"), ("七點十分鐘", "七點十分鐘"), ("兩萬五千塊", "2.5萬塊"),
            ("一二三木頭人", "一二三木頭人"),
            // No band-name cue is supplied for 五五六六; §4.1's explicit bare >=4 rule applies.
            ("五五六六", "5566"), ("一千零一夜", "一千零一夜"), ("十萬火急", "十萬火急"),
            ("千萬富翁", "千萬富翁"), ("三百六十行", "三百六十行"),
            ("三塊蛋糕", "三塊蛋糕"), ("他五度被提名", "他五度被提名")
        ])
        XCTAssertEqual(NumberNormalizer.normalize("the twenty fourth of May").text, "the 24th of May")
    }

    func testUnitAndMeasureWordPolicyVerbatim() {
        for unit in ChineseNumberTables.units where unit != "塊" && unit != "块" {
            check([("二" + unit, "2" + unit)])
            let one = ChineseNumberTables.starredUnits.contains(unit) ? "1" : "一"
            check([("一" + unit, one + unit)])
        }
        for measure in ChineseNumberTables.measures + ChineseNumberTables.additionalMeasures {
            check([("三" + measure, "三" + measure), ("十二" + measure, "12" + measure), ("一" + measure, "一" + measure)])
        }
        check([("一塊蛋糕", "一塊蛋糕"), ("一下", "一下"), ("一秒", "一秒"), ("一歲", "一歲"), ("一元", "一元")])
    }

    func testMoneyCuesAndDegreeOccurrences() {
        check([("三塊", "三塊"), ("三塊錢", "3塊錢"), ("十塊", "10塊"), ("三元", "3元"), ("一塊八", "1.8塊")])
        for cue in ChineseNumberTables.priceCues {
            check([(cue + "三塊", cue + "3塊"), (cue + "好好好好三塊", cue + "好好好好3塊"),
                   (cue + "好好好好好好三塊", cue + "好好好好好好三塊")])
        }
        for occurrence in ChineseNumberTables.degreeOccurrences {
            check([("他五度" + occurrence, "他五度" + occurrence)])
        }
    }

    func testTimesDecimalsAndVersions() {
        check([
            ("三點半", "3:30"), ("九點十五分", "9:15"), ("七點五十分", "7:50"),
            ("下午兩點零五", "下午2:05"), ("下午兩點", "下午2點"), ("三點鐘", "3點鐘"),
            ("下午約一點", "下午約1點"), ("今天開會一點", "今天開會1點"),
            ("一點開會", "1點開會"), ("星期三一點", "星期三1點"),
            ("兩點零五", "2.05"), ("三點一四", "3.14"), ("三點十五", "三點十五"),
            ("零點五點十六", "0.5.16"), ("一點零五點三", "1.05.3"),
            ("下午二十五點十分", "下午二十五點十分"), ("七點六十分", "七點六十分"),
            ("下午兩點零零五", "下午兩點零零五"),
            ("七點十分鐘", "七點十分鐘"), ("一點點", "一點點"), ("十分重要", "十分重要")
        ])
        for cue in ChineseNumberTables.timeCues + ["禮拜一", "星期三", "週四", "周五"] {
            check([(cue + "兩點零五", cue + "2:05"), (cue + "開會三點", cue + "開會3點"),
                   (cue + "開會講了三點", cue + "開會講了三點")])
        }
        for suffix in ChineseNumberTables.timeSuffixes {
            let out = suffix == "半" ? "3:30" : "3點" + suffix
            check([("三點" + suffix, out)])
        }
    }

    func testAmountsAndStrictParser() {
        check([
            ("四萬五千", "4.5萬"), ("兩萬五千", "2.5萬"), ("兩萬五", "2.5萬"),
            ("一億兩千萬", "1.2億"), ("三千萬", "3000萬"), ("兩千五萬", "2500萬"),
            ("兩百五", "250"), ("三萬五", "3.5萬"), ("三億五", "3.5億"),
            ("一百萬五", "一百萬五"), ("十萬五", "十萬五"), ("一萬零五", "10005"),
            ("一千零三十", "1030"), ("三百二十元", "320元"), ("一億零一", "一億零一"),
            ("一億零一萬", "1.0001億"), ("九千九百九十九萬", "9999萬"),
            ("三萬5千", "3.5萬"), ("3萬五", "3.5萬"), ("3萬5千", "3.5萬"),
            ("2026年三月", "2026年3月"), ("三點五萬", "3.5萬"), ("兩萬百千", "兩萬百千"),
            ("A3萬五", "A3萬五"), ("1.3萬五", "1.3萬五"), ("1:3萬五", "1:3萬五")
        ])
        XCTAssertEqual(NumberNormalizer.normalize("两萬五").text, "2.5萬")
    }

    func testBareNumbersProtectLexiconAndApproximation() {
        check([
            ("路易十六", "路易十六"), ("十足", "十足"), ("我今年三十", "我今年30"),
            ("三十出頭", "30出頭"), ("九十九", "九十九"), ("一百", "100"),
            ("一百的", "100的"), ("一百左右", "100左右"), ("一百多", "100多"), ("一百以上", "100以上"), ("一百以下", "100以下"),
            ("一百上下", "100上下"), ("一百吧", "100吧"), ("一百了", "100了"),
            ("一百美元", "100美元"), ("一百富翁", "一百富翁"),
            ("三四十", "三四十"), ("五六百萬", "五六百萬"), ("十幾", "十幾"),
            ("二十多", "二十多"), ("兩三個", "兩三個"), ("七八十", "七八十"), ("三分之一", "三分之一"),
            ("五月天十二首", "五月天12首") // Protect the band locally, convert the separate count.
        ])
        for word in ChineseNumberTables.protectedWords + ChineseNumberTables.additionalProtectedWords {
            check([(word, word)])
        }
        for suffix in ["不", "別", "要", "記", "小心", "注意", "拜託", "保重"] {
            check([("千萬" + suffix, "千萬" + suffix)])
        }
        check([("我一定要買十二個", "我一定要買12個"), ("萬一失敗買十二個", "萬一失敗買12個")])
    }

    func testOrdinalsDatesYearsAndDigitStrings() {
        check([
            ("第一", "第一"), ("第十", "第十"), ("第十一", "第11"), ("第一百零一", "第101"),
            ("第101", "第101"), ("第三名到第十二名", "第三名到第12名"),
            ("一月一日", "1月1日"), ("十二月三十一號", "12月31號"), ("十三月", "十三月"),
            ("二十九號", "29號"), ("三號", "三號"), ("三十二號房", "32號房"),
            ("一九九零年", "1990年"), ("二〇二六年", "2026年"), ("二十一世紀", "21世紀"), ("九十年代", "90年代"),
            ("零九一二三四五六七八", "0912345678"), ("幺三八零", "1380"), ("九二一地震", "921地震"),
            ("一一七名", "117名"), ("一二三", "一二三"), ("五五六六", "5566"),
            ("房間三零五", "房間305"), ("撥一二三", "撥123"), ("分機一二三", "分機123"),
            ("一二三木頭人", "一二三木頭人"), ("一一七大樓", "117大樓")
        ])
    }

    func testPercentsModelsPairsAndSigns() {
        check([
            ("百分之四十三點二", "43.2%"), ("負百分之三點五", "-3.5%"), ("百分之百", "百分之百"),
            ("iPhone十七", "iPhone17"), ("N二", "N2"), ("Q三", "Q3"), ("Sprint 二十三", "Sprint 23"),
            ("iPad 一台", "iPad 一台"), ("email 兩封", "email 兩封"), ("email 二十三", "email 二十三"),
            ("三比二", "3比2"), ("一比一", "1比1"), ("十比八", "10比8"),
            ("十到十五個", "10到15個"), ("三到十二個", "3到12個"),
            ("三到四個", "三到四個"), ("三-十二個", "三-12個"), ("負三十公斤", "-30公斤"),
            ("體感負五度", "體感-5度"), ("負三點五", "-3.5"), ("欺負十二個人", "欺負12個人"),
            ("勝負一百場", "勝負100場"), ("負責十二件", "負責12件")
        ])
        check([("勝負五度", "勝負五度"), ("七點twenty", "七點twenty"),
               ("6度七ten", "6度七ten"), ("N十負三萬", "N十負3萬"),
               ("N2 千", "N2 千"), ("90 兩億", "90 2億"),
               ("am四pm 四version", "am四pm 四version")])
        for connector in ["到", "至", "~", "～"] {
            check([("三" + connector + "十二個", "3" + connector + "12個")])
        }
    }

    func testCoordinatorApprovedFLEURSWordListAdditions() {
        // Literal test lists are independent of the production tables.
        for word in "例 碟 盤 道 首 輪 局 場 根 片 名 戶 床 艘 頂".split(separator: " ") {
            check([("十二" + word, "12" + word), ("三" + word, "三" + word)])
        }
        for word in "英尺 英里 英寸 呎 碼 磅 盎司 公頃 平方公尺 平方公里 法郎 歐元 英鎊 日元 日圓 韓元 盧比 比索 披索 新台幣 新臺幣".split(separator: " ") {
            check([("二" + word, "2" + word), ("一" + word, "一" + word)])
        }
        check([("四十萬例", "40萬例"), ("一百英尺", "100英尺"), ("一百零八碟", "108碟"),
               ("得了三十六分", "得了36分"), ("Scotturp四零三路", "Scotturp403路"),
               ("五百剛果法郎", "500剛果法郎"), ("一剛果法郎", "一剛果法郎"),
               ("五百法郎", "500法郎"), ("一百分", "100分"), ("差三分", "差三分"),
               ("十分感謝", "十分感謝"), ("十分重要", "十分重要"), ("四零三路", "403路"),
               ("一路", "一路"), ("三點七十分", "三點七十分"), ("存款負五十萬", "存款負50萬")])
    }

    func testV23D1AndA2LatinGluedCounts() {
        check([
            ("我買了iPad一臺。", "我買了iPad一臺。"),
            ("我買了iPad一台。", "我買了iPad一台。"),
            ("買了MacBook兩台", "買了MacBook兩台"),
            ("訂了Uber一輛", "訂了Uber一輛"),
            ("我有iPhone三支", "我有iPhone三支"),
            ("iPad一臺", "iPad一臺"), ("iPad一台", "iPad一台"),
            ("MacBook兩台", "MacBook兩台"), ("Type-C三條", "Type-C三條"),
            ("AirPods一副", "AirPods一副"),
            ("iPhone十七台", "iPhone17台"), ("Pixel十個", "Pixel10個"),
            ("AirPods十二副", "AirPods12副"),
            ("三副", "三副"), ("十二副", "12副"),
            ("4K十台", "4K10台"), ("3D十個", "3D10個")
        ])
    }

    func testV23D1ModelCodeNoRegressions() {
        check([
            ("iPhone十七跟Pixel十", "iPhone17跟Pixel10"),
            ("台積電N二製程", "台積電N2製程"), ("N三好", "N3好"),
            ("COVID十九疫情", "COVID19疫情"),
            ("Windows十一月", "Windows11月"),
            ("Sprint二十三", "Sprint23"),
            ("iPad 一台", "iPad 一台"), ("iPad一臺Pro", "iPad一臺Pro"),
            ("5G三年", "5G三年"), ("4K三台", "4K三台"),
            ("3D三個", "3D三個"), ("5G一", "5G一"), ("5G三", "5G3")
        ])
    }

    func testV23D2AndA3LatinGluedModelSuffixes() {
        check([
            ("Q三Revenue", "Q3Revenue"), ("FY二五Budget", "FY25Budget"),
            ("H一Plan", "H1Plan"), ("GPT五Turbo", "GPT5Turbo"),
            ("iPhone十七Pro", "iPhone17Pro"),
            ("iPhone十七Pro Max", "iPhone17Pro Max"),
            ("Galaxy S二十五Ultra", "Galaxy S25Ultra"),
            ("am四pm", "am四pm"), ("iPad一臺Pro", "iPad一臺Pro"),
            // Both exception branches and their token/case boundaries.
            ("ABCD五turbo", "ABCD5turbo"), ("ABCDE五turbo", "ABCDE五turbo"),
            ("gpt五turbo", "gpt五turbo"), ("iPhone十七pro", "iPhone十七pro"),
            ("iPhone二五Pro", "iPhone25Pro"), ("Q零三Revenue", "Q03Revenue"),
            ("Q一二三Revenue", "Q123Revenue"),
            ("FY二五budget", "FY25budget"), ("fy二五budget", "fy二五budget"),
            ("iPhone三GB", "iPhone3GB")
        ])
    }

    func testV23A3TimeBranchKeepsPriority() {
        check([
            ("PM三點Call你", "PM三點Call你"),
            ("PM三點半Call你", "PM3:30Call你"),
            ("PM三點十分Call你", "PM3:10Call你"),
            ("下午PM三點Call你", "下午PM3點Call你")
        ])
    }
    func testReviewRound3bSection9() {
        check([
            ("房租三萬一個月", "房租3萬一個月"),
            ("房租三万一个月", "房租3万一个月"),
            ("兩萬一個人", "2萬一個人"),
            ("两万一个人", "2万一个人"),
            ("三萬一年", "3萬一年"),
            ("三万一年", "3万一年"),
            ("五百塊一個", "500塊一個"),
            ("五百块一个", "500块一个"),
            ("一千塊一天", "1000塊一天"),
            ("一千块一天", "1000块一天"),
            ("三十塊一杯", "30塊一杯"),
            ("三十块一杯", "30块一杯"),
            ("十塊一個", "10塊一個"),
            ("十块一个", "10块一个"),
            ("千萬十二個", "千萬十二個"),
            ("千万十二个", "千万十二个"),
            ("一千萬十二個", "一千萬十二個"),
            ("一千万十二个", "一千万十二个"),
            ("三點一刻", "3:15"),
            ("三点一刻", "3:15"),
            ("四點三刻", "4:45"),
            ("四点三刻", "4:45"),
            ("五塊五毛", "5.5塊"),
            ("五块五毛", "5.5块"),
            ("三塊八毛", "3.8塊"),
            ("三块八毛", "3.8块"),
            ("三元五角", "3.5元"),
            ("幾十萬", "幾十萬"),
            ("几十万", "几十万"),
            ("好幾百萬", "好幾百萬"),
            ("好几百万", "好几百万"),
            ("數十萬", "數十萬"),
            ("数十万", "数十万"),
            ("上百萬", "上百萬"),
            ("上百万", "上百万"),
            ("近百萬", "近百萬"),
            ("近百万", "近百万"),
            ("破千萬", "破千萬"),
            ("破千万", "破千万"),
            ("5G三年", "5G三年"),
            ("4K三台", "4K三台"),
            ("3D三個", "3D三個"),
            ("3D三个", "3D三个"),
            ("七點到九點", "7點到9點"),
            ("七点到九点", "7点到9点"),
            ("兩點到三點之間", "2點到3點之間"),
            ("两点到三点之间", "2点到3点之间"),
            ("七七八八", "七七八八"),
            ("他是個二百五", "他是個二百五"),
            ("他是个二百五", "他是个二百五"),
            ("三萬零", "三萬零"),
            ("三万零", "三万零"),
            ("三千萬不夠", "3000萬不夠"),
            ("三千万不够", "3000万不够"),
            ("五百萬都不到", "500萬都不到"),
            ("五百万都不到", "500万都不到"),
            ("一百萬還不夠", "100萬還不夠"),
            ("一百万还不够", "100万还不够"),
            ("一百二十萬到一百五十萬之間", "120萬到150萬之間"),
            ("一百二十万到一百五十万之间", "120万到150万之间"),
            ("老闆說這案子三千萬不夠，至少要五千萬", "老闆說這案子3000萬不夠，至少要5000萬"),
            ("老板说这案子三千万不够，至少要五千万", "老板说这案子3000万不够，至少要5000万"),
            ("千萬記得", "千萬記得"),
            ("千万记得", "千万记得"),
            ("中山北路二段三十三巷五號", "中山北路二段33巷5號"),
            ("中山北路二段三十三巷五号", "中山北路二段33巷5号"),
            ("一塊美金", "1塊美金"),
            ("一块美金", "1块美金"),
            ("一萬零五", "10005"),
            ("一万零五", "10005"),
            ("一千萬零一", "10000001"),
            ("一千万零一", "10000001"),
            ("三萬兩千三百", "3.23萬"),
            ("三万两千三百", "3.23万"),
            ("三萬五", "3.5萬"),
            ("三万五", "3.5万"),
            ("三點二刻", "三點二刻"),
            ("三点二刻", "三点二刻"),
            ("三點四刻", "三點四刻"),
            ("三点四刻", "三点四刻"),
            ("二十五點一刻", "二十五點一刻"),
            ("二十五点一刻", "二十五点一刻"),
            ("三十塊一", "30.1塊"),
            ("三十块一", "30.1块"),
            ("兩萬一塊", "2.1萬塊"),
            ("两万一块", "2.1万块"),
            ("五塊五毛錢", "5.5塊錢"),
            ("五块五毛钱", "5.5块钱"),
            ("三元五角錢", "3.5元錢"),
            ("三元五角钱", "3.5元钱"),
            ("約百萬", "約百萬"),
            ("约百万", "约百万"),
            ("上千萬", "上千萬"),
            ("上千万", "上千万"),
            ("數百萬", "數百萬"),
            ("数百万", "数百万"),
            ("5G三", "5G3"),
            ("5G一", "5G一"),
            ("Sprint 二十三", "Sprint 23"),
            ("iPhone十七", "iPhone17"),
            ("七點至一點", "7點至1點"),
            ("七点至一点", "7点至1点"),
            ("近一百萬", "近100萬"),
            ("近一百万", "近100万"),
            ("真二百五", "真二百五"),
            ("很二百五", "很二百五"),
            ("一百到一百五十", "100到150"),
            ("一千不夠", "1000不夠"),
            ("一千不够", "1000不够"),
            ("一千都不夠", "1000都不夠"),
            ("一千都不够", "1000都不够"),
            ("一千還不夠", "1000還不夠"),
            ("一千还不够", "1000还不够"),
            ("百萬", "百萬"),
            ("百万", "百万"),
            ("百萬個", "100萬個"),
            ("百万个", "100万个"),
            ("三十三巷一弄二樓五號", "33巷1弄2樓5號"),
            ("三十三巷一弄二楼五号", "33巷1弄2楼5号"),
            ("中山路十二段五號", "中山路十二段5號"),
            ("中山路十二段五号", "中山路十二段5号"),
            ("兩塊美金", "2塊美金"),
            ("两块美金", "2块美金"),
            ("一塊美元", "1塊美元"),
            ("一块美元", "1块美元"),
            ("一萬兩千三百四十五", "12345"),
            ("一万两千三百四十五", "12345"),
            ("一億兩千三百四十五萬", "1.2345億"),
            ("一亿两千三百四十五万", "1.2345亿"),
            ("一億兩千三百四十五萬零一", "一億兩千三百四十五萬零一"),
            ("一亿两千三百四十五万零一", "一亿两千三百四十五万零一"),
        ])
    }

    func testReviewRound3bAbbreviatedAmountLinkers() {
        check([("一萬五和一百萬五", "1.5萬和一百萬五"), ("三萬五到四萬", "3.5萬到4萬")])
        for linker in ["和", "跟", "或", "與", "与", "及", "到", "至", "比", "～", "~"] {
            check([("三萬五" + linker + "四萬", "3.5萬" + linker + "4萬")])
        }
    }

    func testReviewRound4b() {
        check([
            ("三萬零五百", "3.05萬"),
            ("三万零五百", "3.05万"),
            ("十萬", "10萬"),
            ("十万", "10万"),
            ("十億", "10億"),
            ("十亿", "10亿"),
            ("營收十億", "營收10億"),
            ("营收十亿", "营收10亿"),
            ("大概十萬", "大概10萬"),
            ("大概十万", "大概10万"),
            ("十五萬", "15萬"),
            ("十五万", "15万"),
            ("十二萬三千", "12.3萬"),
            ("十二万三千", "12.3万"),
            ("十二萬五千", "12.5萬"),
            ("十二万五千", "12.5万"),
            ("十二萬零三百", "12.03萬"),
            ("十二万零三百", "12.03万"),
            ("十二億三千萬", "12.3億"),
            ("十二亿三千万", "12.3亿"),
            ("十萬火急", "十萬火急"),
            ("十万火急", "十万火急"),
            ("三萬五到三萬八之間", "3.5萬到3.8萬之間"),
            ("三万五到三万八之间", "3.5万到3.8万之间"),
            ("三萬八以上", "3.8萬以上"),
            ("三万八以上", "3.8万以上"),
            ("三萬五的預算", "3.5萬的預算"),
            ("三万五的预算", "3.5万的预算"),
            ("三塊八到四塊", "3.8塊到4塊"),
            ("三块八到四块", "3.8块到4块"),
            ("五塊五毛到六塊", "5.5塊到6塊"),
            ("五块五毛到六块", "5.5块到6块"),
            ("三點一刻鐘", "3:15"),
            ("三点一刻钟", "3:15"),
            ("等了一刻鐘", "等了一刻鐘"),
            ("等了一刻钟", "等了一刻钟"),
            ("四點三刻鐘", "4:45"),
            ("四点三刻钟", "4:45"),
            ("三元五角到四元", "3.5元到4元"),
            ("三塊八到一塊", "3.8塊到1塊"),
            ("三块八到一块", "3.8块到1块"),
            ("十二塊到三塊蛋糕", "12塊到三塊蛋糕"),
            ("十二块到三块蛋糕", "12块到三块蛋糕"),
            ("三萬八以下", "3.8萬以下"),
            ("三万八以下", "3.8万以下"),
            ("三萬八以內", "3.8萬以內"),
            ("三万八以内", "3.8万以内"),
            ("三萬八以内", "3.8萬以内"),
            ("三萬八之間", "3.8萬之間"),
            ("三万八之间", "3.8万之间"),
            ("三萬八的", "3.8萬的"),
            ("三万八的", "3.8万的"),
        ])
    }

}
