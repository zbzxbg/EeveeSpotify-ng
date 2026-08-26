import Foundation
import NaturalLanguage

/// 整首歌语言占比阈值：CJK 语言占比高于此值才按该语言统一罗马化。
private let romajiLanguageThreshold: Double = 0.5

struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var romanization: LyricsRomanizationStatus
    var translation: LyricsTranslationDto? = nil
    var languageCode: String? = nil
    
    func toSpotifyLyricsData(
        source: String,
        useInstrumentalPlaceholder: Bool = true
    ) -> LyricsData {
        var lyricsData = LyricsData.with {
            $0.timeSynchronized = timeSynced
            $0.restriction = .unrestricted
            $0.providedBy = "\(source) (EeveeSpotify)"
        }
        
        let canRomanize = romanization == .canBeRomanized
        
        if lines.isEmpty {
            if useInstrumentalPlaceholder {
                lyricsData.lines = [
                    LyricsLine.with {
                        $0.content = "song_is_instrumental".localized
                    },
                    LyricsLine.with {
                        $0.content = "let_the_music_play".localized
                    },
                    LyricsLine.with {
                        $0.content = ""
                    }
                ]
            }
        }
        else {
            let sortedLines = lines.sorted { 
                ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0)
            }
            // 整首歌语言占比检测（所有源统一）：占比最高的 CJK 语言 > 阈值时，
            // 作为整首歌的统一路由语言，避免逐行识别把孤立汉字行误判。
            let songLanguage: NLLanguage? = canRomanize
                ? lines.map(\.content).dominantCJKLanguageAbove(threshold: romajiLanguageThreshold)
                : nil
            lyricsData.lines = sortedLines.map { line in
                LyricsLine.with {
                    let content: String
                    if canRomanize {
                        content = line.content.romanizedIfEnabled(languageHint: languageCode, songLanguage: songLanguage)
                    } else if romanization == .romanized {
                        // MxM/Genius 已返回罗马字：统一补首字母大写（含「xxx」装饰符跳过）
                        content = line.content.capitalizingFirstLetterIfAlphabetic()
                    } else {
                        content = line.content
                    }
                    $0.content = content
                    $0.offsetMs = Int32(line.offsetMs ?? 0)
                }
            }
        }
        
        if let translation = translation {
            lyricsData.translation = LyricsTranslation.with {
                $0.languageCode = translation.languageCode
                $0.lines = translation.lines
            }
        }
        
        return lyricsData
    }
}

// MARK: - Per-line Language Routing

/// 按指定语言对单行做罗马化（查对应 user 开关；开关关则原样返回）。
private func romanizeLine(_ line: String, as language: NLLanguage) -> String {
    switch language {
    case .japanese:
        guard UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization") else { return line }
        return line.toJapaneseRomaji().capitalizingFirstLetterIfAlphabetic()
    case .simplifiedChinese, .traditionalChinese:
        guard UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization") else { return line }
        return line.toChinesePinyin().capitalizingFirstLetterIfAlphabetic()
    case .korean:
        guard UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization") else { return line }
        return line.toKoreanRomaja().capitalizingFirstLetterIfAlphabetic()
    default:
        return line
    }
}

extension String {
    /// 优先用整首歌占比检测出的语言（songLanguage，所有源统一），
    /// 否则回退到逐行识别（hint 前缀 → 含假名 → dominantLanguage）。
    func romanizedIfEnabled(languageHint: String? = nil, songLanguage: NLLanguage? = nil) -> String {
        if let songLanguage {
            return romanizeLine(self, as: songLanguage)
        }

        let normalizedHint = languageHint?.lowercased()
        let language: NLLanguage?

        if normalizedHint?.hasPrefix("ja") == true {
            language = .japanese
        } else if normalizedHint?.hasPrefix("ko") == true {
            language = .korean
        } else if normalizedHint?.hasPrefix("zh") == true {
            language = .simplifiedChinese
        } else if unicodeScalars.contains(where: { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                return true
            default:
                return false
            }
        }) {
            language = .japanese
        } else {
            language = NLLanguageRecognizer.dominantLanguage(for: self)
        }

        guard let language else {
            return self
        }

        return romanizeLine(self, as: language)
    }
}

// MARK: - Japanese Romanization

/// 假名（平/片）→ 罗马字映射表。键为平假名码点；
/// 片假名在转换前归一为平假名（减 0x60），只有 ー/ヴ 等例外单独处理。
private let japaneseKanaMap: [UInt32: String] = [
    0x3042: "a", 0x3044: "i", 0x3046: "u", 0x3048: "e", 0x304A: "o",
    0x304B: "ka", 0x304D: "ki", 0x304F: "ku", 0x3051: "ke", 0x3053: "ko",
    0x304C: "ga", 0x304E: "gi", 0x3050: "gu", 0x3052: "ge", 0x3054: "go",
    0x3055: "sa", 0x3057: "shi", 0x3059: "su", 0x305B: "se", 0x305D: "so",
    0x3056: "za", 0x3058: "ji", 0x305A: "zu", 0x305C: "ze", 0x305E: "zo",
    0x305F: "ta", 0x3061: "chi", 0x3064: "tsu", 0x3066: "te", 0x3068: "to",
    0x3060: "da", 0x3062: "ji", 0x3065: "zu", 0x3067: "de", 0x3069: "do",
    0x306A: "na", 0x306B: "ni", 0x306C: "nu", 0x306D: "ne", 0x306E: "no",
    0x306F: "ha", 0x3072: "hi", 0x3075: "fu", 0x3078: "he", 0x307B: "ho",
    0x3070: "ba", 0x3073: "bi", 0x3076: "bu", 0x3079: "be", 0x307C: "bo",
    0x3071: "pa", 0x3074: "pi", 0x3077: "pu", 0x307A: "pe", 0x307D: "po",
    0x307E: "ma", 0x307F: "mi", 0x3080: "mu", 0x3081: "me", 0x3082: "mo",
    0x3084: "ya", 0x3086: "yu", 0x3088: "yo",
    0x3089: "ra", 0x308A: "ri", 0x308B: "ru", 0x308C: "re", 0x308D: "ro",
    0x308F: "wa", 0x3092: "wo", 0x3093: "n",
    0x3041: "a", 0x3043: "i", 0x3045: "u", 0x3047: "e", 0x3049: "o",
    0x3083: "ya", 0x3085: "yu", 0x3087: "yo", 0x308E: "wa", 0x3094: "vu"
]

/// 分写：这些 token（助词等）前面加空格。
private let japaneseParticles: Set<String> = [
    "は", "が", "を", "に", "へ", "と", "で", "も", "の", "や", "か",
    "から", "まで", "より", "だけ", "しか", "など", "ほど", "こそ", "でも",
    "って", "ね", "よ", "な", "ぞ", "ぜ", "わ", "さ", "けど", "けれど", "けれども"
]

/// 助词的特殊读音：は→wa、へ→e（を 的 wo 已在映射表里）。
private let japaneseParticleOverrides: [String: String] = [
    "は": "wa", "へ": "e"
]

/// 连写：这些活用后缀前面不加空格（黏到前一个词上）。
private let japaneseInflectionSuffixes: Set<String> = [
    "た", "て", "ない", "なく", "なかっ", "なけれ",
    "ます", "ました", "ません",
    "し", "せ", "たい", "たく", "そう", "よう", "う", "ず", "ぬ", "ば",
    "だっ", "ちゃっ", "じゃっ", "つつ", "ながら", "らしい", "みたい", "ほしい",
    "る", "れる", "られる", "せる", "させる"
]

/// 这些字符后面不再额外加空格（标点/括号等自带分隔）。
private let japaneseSpaceSeparators: Set<Character> = [
    "、", "。", "！", "？", "!", "?", ",", "，", ".", "．", "…",
    "「", "『", "（", "(", "【", "[", "」", "』", "）", ")", "】", "]",
    "・", "：", ":", "；", ";", "ー", "♪"
]

/// 片假名码点 → 平假名码点；非假名返回 nil。
private func japaneseHiraganaScalar(_ value: UInt32) -> UInt32? {
    if (0x3041...0x3096).contains(value) { return value }
    if (0x30A1...0x30F6).contains(value) { return value - 0x60 }
    return nil
}

/// 小假名 ゃゅょ 对应的元音（拗音用）。
private func japaneseSmallYouonVowel(_ hira: UInt32) -> String? {
    switch hira {
    case 0x3083: return "a"
    case 0x3085: return "u"
    case 0x3087: return "o"
    default: return nil
    }
}

/// 促音：把下一音节的辅音双写。
private func japaneseGeminated(_ romaji: String) -> String {
    guard let first = romaji.first else { return romaji }
    if romaji.hasPrefix("ch") { return "t" + romaji }
    if romaji.hasPrefix("sh") { return "s" + romaji }
    if romaji.hasPrefix("ts") { return "t" + romaji }
    if first.isLetter, !"aeiou".contains(first) {
        return String(first) + romaji
    }
    return romaji
}

/// 纯假名 token 的逐字罗马化。跨 token 的促音状态通过 pendingGeminate 传递。
private func japaneseKanaRomaji(_ text: String, pendingGeminate: inout Bool) -> String {
    let scalars = Array(text.unicodeScalars)
    var result = ""
    var i = 0

    while i < scalars.count {
        let value = scalars[i].value

        // 长音 ー：重复前一个元音（保持 ASCII，避免 macron 等怪字符）
        if value == 0x30FC {
            if let last = result.last, "aeiou".contains(last) {
                result.append(last)
            }
            i += 1
            continue
        }

        // 促音 っ/ッ：先记录，等下一个音节双写辅音
        if value == 0x3063 || value == 0x30C3 {
            pendingGeminate = true
            i += 1
            continue
        }

        guard let hira = japaneseHiraganaScalar(value),
              let base = japaneseKanaMap[hira] else {
            // 无法转写的字符（ゝ 等）原样保留
            result += String(UnicodeScalar(value)!)
            i += 1
            continue
        }

        var romaji = base

        // 拗音：i 段假名 + 小 ゃ/ゅ/ょ
        if base.count >= 2, base.hasSuffix("i"),
           i + 1 < scalars.count,
           let nextHira = japaneseHiraganaScalar(scalars[i + 1].value),
           let vowel = japaneseSmallYouonVowel(nextHira) {
            let stem = String(base.dropLast())
            if stem.hasSuffix("sh") || stem.hasSuffix("ch") || stem.hasSuffix("j") {
                romaji = stem + vowel
            } else {
                romaji = stem + "y" + vowel
            }
            i += 2
        } else {
            i += 1
        }

        if pendingGeminate {
            romaji = japaneseGeminated(romaji)
            pendingGeminate = false
        }

        result += romaji
    }

    return result
}

private func japaneseIsPureKana(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    return text.unicodeScalars.allSatisfy {
        (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
    }
}

private func japaneseContainsPinyinMarker(_ text: String) -> Bool {
    for ch in text {
        if "áéíóúàèìòùǎěǐǒǔǖǘǚǜüńňǹḿ\u{0301}\u{0300}\u{030C}".contains(ch) {
            return true
        }
    }
    return false
}

/// 清洗 CFStringTokenizer 对含汉字 token 的转写：去掉促音产生的 "~"、
/// 把 "~tsu + 辅音" 修正为辅音双写、折叠内部空格。
private func japaneseSanitizeTranscription(_ text: String, original: String) -> String {
    var s = text
        .replacingOccurrences(of: "～", with: "~")
        .replacingOccurrences(of: "〜", with: "~")

    s = s.replacingOccurrences(of: "~tsu\\s*(ch)", with: "tch", options: .regularExpression)
    s = s.replacingOccurrences(of: "~tsu\\s*([kstnhmrgyzwbdpfjvc])", with: "$1$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "~", with: "")

    // 附着在名词 token 末尾的助词：「私は」这类 tokenizer 没拆出来的 は/へ，
    // 转写以 ha/he 结尾时改读 wa/e，并保留助词前的空格。
    var particleSuffix: String? = nil
    if original.hasSuffix("は"), s.hasSuffix("ha") {
        s = String(s.dropLast(2)) + "wa"
        particleSuffix = "wa"
    } else if original.hasSuffix("へ"), s.hasSuffix("he") {
        s = String(s.dropLast(2)) + "e"
        particleSuffix = "e"
    }

    s = s.replacingOccurrences(of: " ", with: "")

    if let suffix = particleSuffix, s.hasSuffix(suffix) {
        s = String(s.dropLast(suffix.count)) + " " + suffix
    }

    return s
}

extension String {
    /// 把日语（假名+汉字）转为罗马字：
    /// - 假名部分用映射表逐字转换（正确处理促音/拗音/长音/拨音，无怪符号）；
    /// - 汉字部分用 CFStringTokenizer 取读音，遇到拼音回退时保留原文；
    /// - 分写按语法：助词前加空格，活用后缀黏连。
    func toJapaneseRomaji() -> String {
        guard !isEmpty else { return self }

        let cfText = self as CFString
        let length = CFStringGetLength(cfText)
        let locale = NSLocale(localeIdentifier: "ja") as CFLocale

        let options: CFOptionFlags = kCFStringTokenizerUnitWordBoundary
            | kCFStringTokenizerAttributeLatinTranscription

        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText, CFRangeMake(0, length), options, locale
        )

        func substring(_ range: CFRange) -> String {
            guard range.length > 0,
                  let cf = CFStringCreateWithSubstring(kCFAllocatorDefault, cfText, range)
            else { return "" }
            return cf as String
        }

        var result = ""
        var cursor: CFIndex = 0
        var pendingGeminate = false
        var hasToken = false

        func appendGap(upTo location: CFIndex) {
            guard location > cursor else { return }
            result += substring(CFRangeMake(cursor, location - cursor))
            cursor = location
        }

        func needsSpaceBeforeToken() -> Bool {
            guard hasToken, let last = result.last else { return false }
            if last.isWhitespace || last.isNewline { return false }
            if japaneseSpaceSeparators.contains(last) { return false }
            return true
        }

        func appendToken(_ romaji: String, original: String) {
            guard !romaji.isEmpty else { return }
            let glue = japaneseInflectionSuffixes.contains(original)
            if needsSpaceBeforeToken(), !glue {
                result += " "
            }
            result += romaji
            hasToken = true
        }

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while !tokenType.isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            appendGap(upTo: range.location)

            let original = substring(range)

            var romaji: String
            if japaneseIsPureKana(original) {
                romaji = japaneseKanaRomaji(original, pendingGeminate: &pendingGeminate)
            } else {
                pendingGeminate = false
                if let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer, kCFStringTokenizerAttributeLatinTranscription
                ) as? String, !japaneseContainsPinyinMarker(transcription) {
                    romaji = japaneseSanitizeTranscription(transcription, original: original)
                } else {
                    romaji = original
                }
            }

            // 助词 は/へ 的特殊读音
            if japaneseParticles.contains(original) {
                romaji = japaneseParticleOverrides[original] ?? romaji
            }

            appendToken(romaji, original: original)

            cursor = range.location + range.length
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        appendGap(upTo: length)

        return result
    }

    /// 把行首第一个字母大写；「xxx」这类以开括号/引号/空白/零宽字符开头的行会跳过
    /// 这些装饰/隐形前缀，大写其后的第一个字母，其余字母保持原样。
    /// 其它非字母开头（省略号、数字、♪ 等）整行原样返回，避免误大写续行。
    func capitalizingFirstLetterIfAlphabetic() -> String {
        let leadingDecorations: Set<Character> = [
            // 开括号 / 引号 / 装饰符号
            "「", "『", "（", "(", "【", "[", "《", "〈", "〖", "〔", "〘", "«", "‹", "｢",
            "\"", "'", "`", "・", "･",
            // 空白与零宽/隐形字符
            " ", "\u{3000}", "\u{00A0}", "\u{2007}", "\u{202F}",
            "\u{200B}", "\u{FEFF}", "\u{200C}", "\u{200D}", "\u{2060}"
        ]
        var index = startIndex
        while index < endIndex, leadingDecorations.contains(self[index]) {
            index = self.index(after: index)
        }
        guard index < endIndex, self[index].isLetter else { return self }
        let afterLetter = self.index(after: index)
        return String(self[..<index])
            + String(self[index]).uppercased()
            + String(self[afterLetter...])
    }
}

// MARK: - Chinese & Korean Romanization

extension String {
    /// 使用系统 ICU 转写引擎（Han-Latin）把中文（简/繁）转为带声调拼音。
    /// 中文不存在日语汉字那种多音字歧义问题（每行已经过 NLLanguageRecognizer
    /// 确认是中文），所以可以直接用系统的 .toLatin，不需要像日语那样自己分词。
    func toChinesePinyin() -> String {
        guard !isEmpty else { return self }
        return self.applyingTransform(.toLatin, reverse: false) ?? self
    }

    /// 使用系统 ICU 转写引擎把韩文谚文转为罗马字（Revised Romanization）。
    /// 谚文是表音文字，一个字符对应固定读音，没有多音字问题，
    /// 同样可以直接用系统的 .toLatin。
    func toKoreanRomaja() -> String {
        guard !isEmpty else { return self }
        return self.applyingTransform(.toLatin, reverse: false) ?? self
    }
}
