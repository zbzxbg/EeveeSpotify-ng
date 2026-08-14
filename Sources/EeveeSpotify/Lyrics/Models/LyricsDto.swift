import Foundation

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
                    $0.content = (shouldRomanize && romanization == .canBeRomanized)
                        ? line.content.toJapaneseRomaji().capitalizingFirstLetterIfAlphabetic()
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

// MARK: - Japanese Romanization

extension String {
    /// 使用 CFStringTokenizer 的日语形态分析引擎将假名/汉字转为平文式罗马音。
    /// 相比 .toLatin(会把汉字当中文拼音处理),这里汉字会按日语读音转换。
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

        // 是否需要在 token 前插入空格：如果结果末尾已经是空白/换行，
        // 或者末尾是开括号/开引号类字符(「、(、[、" 等),就不需要再加空格,
        // 避免出现 "「 Genki" 这种开头多一个空格的情况。
        func needsSpace(beforeAppendingTo result: String) -> Bool {
            guard let last = result.last, !last.isWhitespace, !last.isNewline else {
                return false
            }
            if let scalar = last.unicodeScalars.first {
                switch scalar.properties.generalCategory {
                case .openPunctuation, .initialPunctuation:
                    return false
                default:
                    break
                }
            }
            return true
        }

        func appendToken(_ text: String) {
            guard !text.isEmpty else { return }
            if needsSpace(beforeAppendingTo: result) {
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
    /// 现在允许前导空白：跳过前导空白后，检查第一个非空白字符。
    /// 如果该字符是字母，则大写它；如果是「，则跳过「及「后的空白，
    /// 将紧跟的字母大写。
    /// 只处理字符串开头附近的第一个「，后续的「不处理。
    func capitalizingFirstLetterIfAlphabetic() -> String {
        // 找到第一个非空白字符
        guard let firstNonWhitespaceIndex = self.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) else {
            return self
        }
        
        let leading = self[..<firstNonWhitespaceIndex] // 前导空白
        let rest = self[firstNonWhitespaceIndex...]    // 从第一个非空白开始

        guard let first = rest.first else { return self }
        
        if first.isLetter {
            return String(leading) + first.uppercased() + String(rest.dropFirst())
        }
        
        if first == "「" {
            let afterQuote = rest.dropFirst()
            let leadingWhitespace = afterQuote.prefix(while: { $0.isWhitespace })
            let remainder = afterQuote.dropFirst(leadingWhitespace.count)
            
            if let letter = remainder.first, letter.isLetter {
                return String(leading) + "「" + String(leadingWhitespace) + letter.uppercased() + String(remainder.dropFirst())
            }
        }
        
        return self
    }
}