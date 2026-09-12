import CoreText
import SwiftUI
import UIKit

// 移植自 MeloX `MeloX/Features/Player/Lyrics/Shared/TimedLyricTextBuilder.swift`（GPL-3.0）。
//
// 与 MeloX 的唯一实现差异：MeloX 用 `reduce(into:)` + `LyricAttributedText.append`
// 逐字拼接（每追加一次都可能触发 AttributedString 内部复制），这里改为
// **先拼字符、再按区间一次性写属性**，结果等价但省掉逐字拼接的开销。
// 属性语义、折行算法、缓存策略均保持一致。

private struct LyricTextHorizontalOffset: Hashable {
    let characterOffset: Int
    let horizontalOffset: CGFloat
}

@available(iOS 26.0, *)
@MainActor
enum TimedLyricTextBuilder {
    private static let cache = LyricTextCache()

    static func text(
        from syllables: [LyricSyllable],
        constrainedWidth: CGFloat?,
        fontSize: CGFloat,
        fontWeight: LyricsFontWeight = .bold,
        forcedLineBreakCharacterOffsets: Set<Int>? = nil,
        forcedHorizontalOffsetsByCharacterOffset: [Int: CGFloat] = [:]
    ) -> Text {
        let horizontalOffsets = normalizedHorizontalOffsets(
            forcedHorizontalOffsetsByCharacterOffset
        )
        let key = LyricTextCache.Key.timed(
            syllables: syllables,
            constrainedWidth: constrainedWidth,
            fontSize: fontSize,
            fontWeight: fontWeight.rawValue,
            forcedLineBreakCharacterOffsets: forcedLineBreakCharacterOffsets,
            forcedHorizontalOffsets: horizontalOffsets
        )
        if let cachedText = cache.text(for: key) {
            return cachedText
        }

        let text = makeText(
            from: syllables,
            constrainedWidth: constrainedWidth,
            fontSize: fontSize,
            fontWeight: fontWeight,
            forcedLineBreakCharacterOffsets: forcedLineBreakCharacterOffsets,
            forcedHorizontalOffsets: horizontalOffsets
        )
        cache.insert(text, for: key)
        return text
    }

    static func text(
        from source: String,
        constrainedWidth: CGFloat?,
        fontSize: CGFloat,
        fontWeight: LyricsFontWeight = .bold,
        forcedLineBreakCharacterOffsets: Set<Int>? = nil,
        forcedHorizontalOffsetsByCharacterOffset: [Int: CGFloat] = [:]
    ) -> Text {
        let horizontalOffsets = normalizedHorizontalOffsets(
            forcedHorizontalOffsetsByCharacterOffset
        )
        let key = LyricTextCache.Key.plain(
            source: source,
            constrainedWidth: constrainedWidth,
            fontSize: fontSize,
            fontWeight: fontWeight.rawValue,
            forcedLineBreakCharacterOffsets: forcedLineBreakCharacterOffsets,
            forcedHorizontalOffsets: horizontalOffsets
        )
        if let cachedText = cache.text(for: key) {
            return cachedText
        }

        let text = makeText(
            from: source,
            constrainedWidth: constrainedWidth,
            fontSize: fontSize,
            fontWeight: fontWeight,
            forcedLineBreakCharacterOffsets: forcedLineBreakCharacterOffsets,
            forcedHorizontalOffsets: horizontalOffsets
        )
        cache.insert(text, for: key)
        return text
    }

    // MARK: - 带时间轴的文本

    private static func makeText(
        from syllables: [LyricSyllable],
        constrainedWidth: CGFloat?,
        fontSize: CGFloat,
        fontWeight: LyricsFontWeight,
        forcedLineBreakCharacterOffsets: Set<Int>?,
        forcedHorizontalOffsets: [LyricTextHorizontalOffset]
    ) -> Text {
        let characters = timedCharacters(from: syllables)
        let source = characters.map(\.text).joined()
        let wordTimings = wordTimings(for: characters, source: source)
        let lineBreakOffsets = resolvedLineBreakCharacterOffsets(
            forced: forcedLineBreakCharacterOffsets,
            source: source,
            constrainedWidth: constrainedWidth,
            fontSize: fontSize,
            fontWeight: fontWeight,
            usesTimedRunBoundaries: true
        )

        let horizontalOffsetByCharacterOffset = Dictionary(
            uniqueKeysWithValues: forcedHorizontalOffsets.map {
                ($0.characterOffset, $0.horizontalOffset)
            }
        )

        // 先构建最终字符串（含插入的换行符），并记录每个输出区间对应的
        // 原字符下标，随后一次性写属性。
        var output = ""
        var characterIndexByOutputRange: [(Range<String.Index>, Int)] = []
        var activeHorizontalOffset: CGFloat = 0
        var pendingHorizontalOffsetByOutputOffset: [Int: CGFloat] = [:]

        for (offset, character) in characters.enumerated() {
            if lineBreakOffsets.contains(offset),
               offset > 0,
               !characters[offset - 1].isLineBreak {
                output += "\n"
                activeHorizontalOffset = 0
            }
            if let horizontalOffset = horizontalOffsetByCharacterOffset[offset] {
                activeHorizontalOffset = horizontalOffset
            }

            let start = output.endIndex
            output += character.text
            let range = start..<output.endIndex
            characterIndexByOutputRange.append((range, offset))
            if activeHorizontalOffset != 0 {
                pendingHorizontalOffsetByOutputOffset[output.count - character.text.count] = activeHorizontalOffset
            }
        }

        var attributed = AttributedString(output)

        // 逐字写时间轴属性（白名单属性作用域，见 LyricAttributeScope）。
        for (range, characterOffset) in characterIndexByOutputRange {
            guard let attributedRange = Range(range, in: attributed) else { continue }
            let character = characters[characterOffset]
            let wordTiming = wordTimings[characterOffset]
            attributed[attributedRange][LyricTimingAttributeKey.self] =
                LyricTimingTextAttribute(
                    startTime: character.startTime,
                    endTime: character.endTime,
                    syllableStartTime: character.syllableStartTime,
                    syllableEndTime: character.syllableEndTime,
                    characterIndex: character.characterIndex,
                    characterCount: character.characterCount,
                    wordStartTime: wordTiming.startTime,
                    wordEndTime: wordTiming.endTime,
                    wordCharacterIndex: wordTiming.characterIndex,
                    wordCharacterCount: wordTiming.characterCount,
                    usesWordTimingForLongTone: wordTiming.usesWordTimingForLongTone,
                    isWhitespace: character.isWhitespace
                )
        }

        // ruby 水平偏移：按字符起点写入。
        if !pendingHorizontalOffsetByOutputOffset.isEmpty {
            var runningOffset = 0
            for (range, _) in characterIndexByOutputRange {
                defer { runningOffset = output.distance(from: output.startIndex, to: range.upperBound) }
                guard let horizontalOffset = pendingHorizontalOffsetByOutputOffset[runningOffset],
                      let attributedRange = Range(range, in: attributed) else {
                    continue
                }
                attributed[attributedRange][LyricPlacementAttributeKey.self] =
                    LyricRubyPlacementTextAttribute(horizontalOffset: horizontalOffset)
            }
        }

        return Text(attributed)
    }

    // MARK: - 纯文本（无时间轴）

    private static func makeText(
        from source: String,
        constrainedWidth: CGFloat?,
        fontSize: CGFloat,
        fontWeight: LyricsFontWeight,
        forcedLineBreakCharacterOffsets: Set<Int>?,
        forcedHorizontalOffsets: [LyricTextHorizontalOffset]
    ) -> Text {
        let lineBreakOffsets = resolvedLineBreakCharacterOffsets(
            forced: forcedLineBreakCharacterOffsets,
            source: source,
            constrainedWidth: constrainedWidth,
            fontSize: fontSize,
            fontWeight: fontWeight,
            usesTimedRunBoundaries: false
        )
        guard !lineBreakOffsets.isEmpty
                || !forcedHorizontalOffsets.isEmpty else {
            return Text(verbatim: source)
        }

        let characters = Array(source)
        let horizontalOffsetByCharacterOffset = Dictionary(
            uniqueKeysWithValues: forcedHorizontalOffsets.map {
                ($0.characterOffset, $0.horizontalOffset)
            }
        )
        var activeHorizontalOffset: CGFloat = 0
        var output = ""
        var rangesWithOffsets: [(Range<String.Index>, CGFloat)] = []

        for (offset, character) in characters.enumerated() {
            if lineBreakOffsets.contains(offset),
               offset > 0,
               !characters[offset - 1].isNewline,
               !character.isNewline {
                output += "\n"
                activeHorizontalOffset = 0
            }
            if let horizontalOffset = horizontalOffsetByCharacterOffset[offset] {
                activeHorizontalOffset = horizontalOffset
            }
            let start = output.endIndex
            output.append(character)
            if activeHorizontalOffset != 0 {
                rangesWithOffsets.append((start..<output.endIndex, activeHorizontalOffset))
            }
        }

        guard !rangesWithOffsets.isEmpty else {
            return Text(verbatim: output)
        }

        var attributed = AttributedString(output)
        for (range, horizontalOffset) in rangesWithOffsets {
            guard let attributedRange = Range(range, in: attributed) else { continue }
            attributed[attributedRange][LyricPlacementAttributeKey.self] =
                LyricRubyPlacementTextAttribute(horizontalOffset: horizontalOffset)
        }
        return Text(attributed)
    }

    // MARK: - 折行

    private static func resolvedLineBreakCharacterOffsets(
        forced: Set<Int>?,
        source: String,
        constrainedWidth: CGFloat?,
        fontSize: CGFloat,
        fontWeight: LyricsFontWeight,
        usesTimedRunBoundaries: Bool
    ) -> Set<Int> {
        if let forced {
            let characterCount = source.count
            return Set(
                forced.filter { $0 > 0 && $0 < characterCount }
            )
        }
        return lineBreakCharacterOffsets(
            in: source,
            constrainedWidth: constrainedWidth,
            fontSize: fontSize,
            fontWeight: fontWeight,
            usesTimedRunBoundaries: usesTimedRunBoundaries
        )
    }

    private static func normalizedHorizontalOffsets(
        _ offsets: [Int: CGFloat]
    ) -> [LyricTextHorizontalOffset] {
        offsets.compactMap { characterOffset, horizontalOffset in
            guard characterOffset > 0,
                  horizontalOffset.isFinite,
                  horizontalOffset >= 0 else {
                return nil
            }
            return LyricTextHorizontalOffset(
                characterOffset: characterOffset,
                horizontalOffset: horizontalOffset
            )
        }.sorted { $0.characterOffset < $1.characterOffset }
    }

    // MARK: - 词分组

    private static func wordTimings(
        for characters: [TimedCharacter],
        source: String
    ) -> [WordTiming] {
        var result = characters.map { character in
            WordTiming(
                startTime: character.startTime,
                endTime: character.endTime,
                characterIndex: 0,
                characterCount: 1,
                usesWordTimingForLongTone: false
            )
        }

        for range in LyricWordSegmenter.blockRanges(in: source) {
            guard range.lowerBound >= characters.startIndex,
                  range.upperBound <= characters.endIndex,
                  range.lowerBound < range.upperBound else {
                continue
            }

            let timedIndices = range.filter {
                !characters[$0].isWhitespace
            }
            guard let startTime = timedIndices
                .map({ characters[$0].startTime })
                .min(),
                let endTime = timedIndices
                    .map({ characters[$0].endTime })
                    .max() else {
                continue
            }
            let characterPositions = Dictionary(
                uniqueKeysWithValues: timedIndices.enumerated().map {
                    ($0.element, $0.offset)
                }
            )
            // 多字母拉丁词才用「词级」长音判定；CJK 退回按字判定。
            let usesWordTimingForLongTone =
                timedIndices.count > 1
                    && timedIndices.allSatisfy {
                        characters[$0].isLatinLetter
                    }
            for index in range {
                result[index] = WordTiming(
                    startTime: startTime,
                    endTime: endTime,
                    characterIndex:
                        characterPositions[index]
                            ?? max(timedIndices.count - 1, 0),
                    characterCount: max(timedIndices.count, 1),
                    usesWordTimingForLongTone: usesWordTimingForLongTone
                )
            }
        }
        return result
    }

    /// 音节 → 逐字。**音节时长按字数均分**，末字吸附到音节 endTime 吸收浮点漂移。
    /// 这是「逐字填充」的最底层粒度来源。
    private static func timedCharacters(
        from syllables: [LyricSyllable]
    ) -> [TimedCharacter] {
        syllables.flatMap { syllable -> [TimedCharacter] in
            let characters = Array(syllable.text)
            guard !characters.isEmpty else { return [] }

            let duration = max(
                syllable.endTime - syllable.startTime,
                0
            )
            let characterDuration = duration / Double(characters.count)

            return characters.enumerated().map { entry in
                let startTime = syllable.startTime
                    + Double(entry.offset) * characterDuration
                let endTime = entry.offset == characters.count - 1
                    ? max(syllable.endTime, startTime)
                    : startTime + characterDuration
                return TimedCharacter(
                    text: String(entry.element),
                    startTime: startTime,
                    endTime: endTime,
                    syllableStartTime: syllable.startTime,
                    syllableEndTime: syllable.endTime,
                    characterIndex: entry.offset,
                    characterCount: characters.count
                )
            }
        }
    }

    // MARK: - 用 Core Text 求折行点

    private static func lineBreakCharacterOffsets(
        in source: String,
        constrainedWidth: CGFloat?,
        fontSize: CGFloat,
        fontWeight: LyricsFontWeight,
        usesTimedRunBoundaries: Bool
    ) -> Set<Int> {
        guard !source.isEmpty,
              let constrainedWidth,
              constrainedWidth.isFinite,
              constrainedWidth > 0,
              fontSize.isFinite,
              fontSize > 0 else {
            return []
        }

        let uiFont = UIFont.systemFont(
            ofSize: fontSize,
            weight: fontWeight.uiKitWeight
        )
        let layoutFont = CTFontCreateWithName(
            uiFont.fontName as CFString,
            fontSize,
            nil
        )
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): layoutFont,
        ]
        if usesTimedRunBoundaries {
            // 逐字属性化会把字形切成独立 run，连字会让测量与渲染不一致。
            attributes[NSAttributedString.Key(kCTLigatureAttributeName as String)] = 0
        }
        let attributedText = NSMutableAttributedString(
            string: source,
            attributes: attributes
        )
        if usesTimedRunBoundaries {
            addTimedRunBoundaries(to: attributedText, source: source)
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributedText)
        let utf16Length = attributedText.length
        var utf16Offset = 0
        var result: Set<Int> = []
        let layoutWidth = effectiveLayoutWidth(
            source: source,
            constrainedWidth: constrainedWidth,
            fontSize: fontSize,
            usesTimedRunBoundaries: usesTimedRunBoundaries
        )

        while utf16Offset < utf16Length {
            let suggestedLength = CTTypesetterSuggestLineBreak(
                typesetter,
                utf16Offset,
                Double(layoutWidth)
            )
            let consumedLength = max(
                suggestedLength,
                nextCharacterLength(in: source, atUTF16Offset: utf16Offset)
            )
            let nextOffset = min(utf16Offset + consumedLength, utf16Length)
            guard nextOffset > utf16Offset else { break }
            utf16Offset = nextOffset

            if utf16Offset < utf16Length,
               let characterOffset = characterOffset(in: source, utf16Offset: utf16Offset),
               characterOffset > 0 {
                result.insert(characterOffset)
            }
        }
        return result
    }

    private static func effectiveLayoutWidth(
        source: String,
        constrainedWidth: CGFloat,
        fontSize: CGFloat,
        usesTimedRunBoundaries: Bool
    ) -> CGFloat {
        let containsLatinText = source.unicodeScalars.contains { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
        }
        let containsWordSpacing = source.contains { $0.isWhitespace }
        let safetyMargin: CGFloat
        if usesTimedRunBoundaries, containsLatinText, containsWordSpacing {
            // 逐字属性化后，SwiftUI 在词边界附近测得比 Core Text 更宽，
            // 不给余量会出现「算出能放下、渲染时溢出」的错行。
            safetyMargin = max(constrainedWidth * 0.05, fontSize * 0.5)
        } else {
            safetyMargin = max(fontSize * 0.02, 0.5)
        }
        return max(constrainedWidth - safetyMargin, 1)
    }

    private static func addTimedRunBoundaries(
        to attributedText: NSMutableAttributedString,
        source: String
    ) {
        let runBoundaryAttribute = NSAttributedString.Key(
            "EeveeSpotifyTimedLyricRunBoundary"
        )
        var utf16Offset = 0
        for (characterOffset, character) in source.enumerated() {
            let utf16Length = String(character).utf16.count
            attributedText.addAttribute(
                runBoundaryAttribute,
                value: characterOffset,
                range: NSRange(location: utf16Offset, length: utf16Length)
            )
            utf16Offset += utf16Length
        }
    }

    private static func nextCharacterLength(
        in source: String,
        atUTF16Offset offset: Int
    ) -> Int {
        guard offset < source.utf16.count else { return 0 }
        let range = (source as NSString).rangeOfComposedCharacterSequence(at: offset)
        return max(range.location + range.length - offset, 1)
    }

    private static func characterOffset(
        in source: String,
        utf16Offset: Int
    ) -> Int? {
        let utf16 = source.utf16
        guard let utf16Index = utf16.index(
            utf16.startIndex,
            offsetBy: utf16Offset,
            limitedBy: utf16.endIndex
        ),
        let stringIndex = String.Index(utf16Index, within: source) else {
            return nil
        }
        return source.distance(from: source.startIndex, to: stringIndex)
    }
}

// MARK: - 缓存

@available(iOS 26.0, *)
@MainActor
private final class LyricTextCache {
    enum Key: Hashable {
        case timed(
            syllables: [LyricSyllable],
            constrainedWidth: CGFloat?,
            fontSize: CGFloat,
            fontWeight: String,
            forcedLineBreakCharacterOffsets: Set<Int>?,
            forcedHorizontalOffsets: [LyricTextHorizontalOffset]
        )
        case plain(
            source: String,
            constrainedWidth: CGFloat?,
            fontSize: CGFloat,
            fontWeight: String,
            forcedLineBreakCharacterOffsets: Set<Int>?,
            forcedHorizontalOffsets: [LyricTextHorizontalOffset]
        )
    }

    private static let maximumEntryCount = 256
    private var storage: [Key: Text] = [:]
    private var insertionOrder: [Key] = []

    func text(for key: Key) -> Text? {
        storage[key]
    }

    func insert(_ text: Text, for key: Key) {
        guard storage[key] == nil else { return }
        storage[key] = text
        insertionOrder.append(key)

        let overflow = insertionOrder.count - Self.maximumEntryCount
        guard overflow > 0 else { return }
        for expiredKey in insertionOrder.prefix(overflow) {
            storage.removeValue(forKey: expiredKey)
        }
        insertionOrder.removeFirst(overflow)
    }
}

// MARK: - 内部类型

@available(iOS 26.0, *)
private extension TimedLyricTextBuilder {
    struct WordTiming {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let characterIndex: Int
        let characterCount: Int
        let usesWordTimingForLongTone: Bool
    }

    struct TimedCharacter {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let syllableStartTime: TimeInterval
        let syllableEndTime: TimeInterval
        let characterIndex: Int
        let characterCount: Int

        var isLineBreak: Bool {
            text == "\n" || text == "\r" || text == "\r\n"
        }

        var isWhitespace: Bool {
            text.allSatisfy(\.isWhitespace)
        }

        var isLatinLetter: Bool {
            !text.isEmpty
                && text.unicodeScalars.allSatisfy { scalar in
                    (65...90).contains(scalar.value)
                        || (97...122).contains(scalar.value)
                }
        }
    }
}
