import Foundation
import NaturalLanguage

struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var romanization: LyricsRomanizationStatus
    var translation: LyricsTranslationDto?
    
    func toSpotifyLyricsData(source: String) -> LyricsData {
        var lyricsData = LyricsData.with {
            $0.timeSynchronized = timeSynced
            $0.restriction = .unrestricted
            $0.providedBy = "\(source) (EeveeSpotify)"
        }
        
        let shouldRomanize = UserDefaults.lyricsOptions.romanization
        let canRomanize = shouldRomanize && romanization == .canBeRomanized
        
        if lines.isEmpty {
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
        else {
            let sortedLines = lines.sorted { 
                ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0)
            }
            lyricsData.lines = sortedLines.map { line in
                LyricsLine.with {
                    $0.content = canRomanize
                        ? line.content.romanizedIfEnabled()
                        : line.content
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

extension String {
    /// 全局开关（shouldRomanize && canBeRomanized）已在调用方检查过。
    /// 这里只负责：识别这一行具体是什么语言 -> 查对应语言开关 -> 用对应转换器。
    /// 逐行识别，避免像 applyingTransform(.toLatin) 那样把整段文本按单一语言处理，
    /// 导致日语汉字被当成中文拼音、中日混排歌词转写错乱的问题。
    func romanizedIfEnabled() -> String {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: self) else {
            return self
        }
        
        switch language {
        case .japanese:
            guard UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization") else { return self }
            return self.toJapaneseRomaji().capitalizingFirstLetterIfAlphabetic()
            
        case .simplifiedChinese, .traditionalChinese:
            guard UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization") else { return self }
            return self.toChinesePinyin().capitalizingFirstLetterIfAlphabetic()
            
        case .korean:
            guard UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization") else { return self }
            return self.toKoreanRomaja().capitalizingFirstLetterIfAlphabetic()
            
        default:
            return self
        }
    }
}

// MARK: - Japanese Romanization

extension String {
    /// 使用 CFStringTokenizer 的日语形态分析引擎将假名/汉字转为平文式罗马音。
    /// 相比 .toLatin(会把汉字当中文拼音处理),这里汉字会按日语读音转换。
    /// 日语汉字存在"多音字"问题（同一个字在不同词里读音不同），
    /// 必须先分词再查词典才能读对，所以不能直接用系统的 .toLatin。
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

        func appendGap(upTo location: CFIndex) {
            guard location > cursor else { return }
            result += substring(CFRangeMake(cursor, location - cursor))
            cursor = location
        }

        func appendToken(_ text: String) {
            guard !text.isEmpty else { return }
            if let last = result.last, !last.isWhitespace, !last.isNewline {
                result += " "
            }
            result += text
        }

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while !tokenType.isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            appendGap(upTo: range.location)

            if let romaji = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription
            ) as? String {
                appendToken(romaji)
            } else {
                appendToken(substring(range))
            }

            cursor = range.location + range.length
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        appendGap(upTo: length)

        return result
    }

    /// 把首字符大写，前提是首字符本身是字母。
    /// 如果首字符是标点、符号或 ♪ 这类非字母字符，整行原样返回，不做任何处理。
    func capitalizingFirstLetterIfAlphabetic() -> String {
        guard let first = self.first, first.isLetter else { return self }
        return first.uppercased() + self.dropFirst()
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
