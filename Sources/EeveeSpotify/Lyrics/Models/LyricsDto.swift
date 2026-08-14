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