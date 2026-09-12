import Foundation
import NaturalLanguage

// 移植自 MeloX `MeloX/Core/Lyrics/LyricWordSegmenter.swift`（GPL-3.0）。

/// 产出「连续字符区间」，用于把一行文本切成一个个词块（驱动逐词的上浮/长音动画）。
/// 逐段（按空白切开的短语）单独分词，可以在行内中英混排、系统分词器中途换语言时仍然覆盖。
enum LyricWordSegmenter {
    static func blockRanges(in text: String) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }

        let textLength = text.count
        let phraseRanges = nonWhitespaceRanges(in: text)
        let segmentedRanges = phraseRanges.flatMap {
            tokenRanges(in: text, phraseRange: $0)
        }
        guard !segmentedRanges.isEmpty else {
            return [0..<textLength]
        }

        return rangesCoveringWhitespace(
            between: segmentedRanges,
            textLength: textLength
        )
    }

    private static func nonWhitespaceRanges(
        in text: String
    ) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var phraseStart: String.Index?

        for index in text.indices {
            if text[index].isWhitespace {
                if let start = phraseStart {
                    result.append(start..<index)
                    phraseStart = nil
                }
            } else if phraseStart == nil {
                phraseStart = index
            }
        }

        if let phraseStart {
            result.append(phraseStart..<text.endIndex)
        }
        return result
    }

    private static func tokenRanges(
        in text: String,
        phraseRange: Range<String.Index>
    ) -> [Range<Int>] {
        let phrase = String(text[phraseRange])
        let phraseOffset = text.distance(
            from: text.startIndex,
            to: phraseRange.lowerBound
        )
        let phraseLength = phrase.count
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = phrase

        var rawRanges: [Range<Int>] = []
        tokenizer.enumerateTokens(
            in: phrase.startIndex..<phrase.endIndex
        ) { tokenRange, _ in
            let lowerBound = phrase.distance(
                from: phrase.startIndex,
                to: tokenRange.lowerBound
            )
            let upperBound = phrase.distance(
                from: phrase.startIndex,
                to: tokenRange.upperBound
            )
            if lowerBound < upperBound {
                rawRanges.append(
                    (phraseOffset + lowerBound)..<(phraseOffset + upperBound)
                )
            }
            return true
        }

        let phraseCharacterRange = phraseOffset..<(phraseOffset + phraseLength)
        return rangesCoveringPunctuation(
            between: rawRanges,
            phraseRange: phraseCharacterRange
        )
    }

    private static func rangesCoveringPunctuation(
        between tokenRanges: [Range<Int>],
        phraseRange: Range<Int>
    ) -> [Range<Int>] {
        let sortedRanges = tokenRanges
            .filter {
                $0.lowerBound >= phraseRange.lowerBound
                    && $0.upperBound <= phraseRange.upperBound
            }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard let firstRange = sortedRanges.first else {
            return [phraseRange]
        }

        // NLTokenizer 会丢掉标点：前导标点并入第一个词，词间/词尾标点并入前一个词。
        var result = [
            phraseRange.lowerBound..<firstRange.upperBound
        ]
        for range in sortedRanges.dropFirst() {
            guard let previous = result.last,
                  range.lowerBound >= previous.upperBound else {
                continue
            }
            result[result.count - 1] = previous.lowerBound..<range.lowerBound
            result.append(range)
        }

        if let last = result.last {
            result[result.count - 1] = last.lowerBound..<phraseRange.upperBound
        }
        return result
    }

    /// 把词间空白并入前一个词块，保证切分结果覆盖整行、不丢空格。
    private static func rangesCoveringWhitespace(
        between tokenRanges: [Range<Int>],
        textLength: Int
    ) -> [Range<Int>] {
        var result: [Range<Int>] = []

        for range in tokenRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound < range.upperBound else { continue }

            if let previous = result.last {
                guard range.lowerBound >= previous.upperBound else { continue }
                result[result.count - 1] = previous.lowerBound..<range.lowerBound
                result.append(range)
            } else {
                result.append(0..<range.upperBound)
            }
        }

        if let last = result.last {
            result[result.count - 1] = last.lowerBound..<textLength
        }
        return result
    }
}
