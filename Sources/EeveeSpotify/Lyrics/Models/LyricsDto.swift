import Foundation

extension String {
    /// 使用 CFStringTokenizer 的日语形态分析引擎将假名/汉字转为平文式罗马音。
    /// 相比 .toLatin，汉字会按日语读音而非拼音转换。
    func toJapaneseRomaji() -> String {
        guard !isEmpty else { return self }

        let cfText = self as CFString
        let length = CFStringGetLength(cfText)
        let locale = CFLocaleCreate(kCFAllocatorDefault, "ja" as CFString)

        // 必须把 Attribute flag 一起 OR 进 options，tokenizer 才会计算罗马音
        let options: CFOptionFlags = kCFStringTokenizerUnitWordBoundary
            | kCFStringTokenizerAttributeLatinTranscription

        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText, CFRangeMake(0, length), options, locale
        )

        var result = ""
        var cursor: CFIndex = 0

        func appendGap(upTo location: CFIndex) {
            guard location > cursor else { return }
            let gap = CFStringCreateWithSubstring(
                kCFAllocatorDefault, cfText, CFRangeMake(cursor, location - cursor)
            )
            result += gap as String
            cursor = location
        }

        func appendToken(_ text: String) {
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
                // 非日语 token（英文单词、数字等）原样保留
                let original = CFStringCreateWithSubstring(
                    kCFAllocatorDefault, cfText, range
                ) as String
                appendToken(original)
            }

            cursor = range.location + range.length
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        appendGap(upTo: length)

        return result
    }
}