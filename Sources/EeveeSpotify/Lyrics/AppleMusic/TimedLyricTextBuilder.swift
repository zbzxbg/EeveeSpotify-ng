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

        // 折行诊断：只在「真的折了」或「文本明显超宽却没折」时各打一条。
        //
        // 用途：分辨两类原因 ——
        //   · 日志里 layout 宽度明显偏小  → 宽度传递问题
        //   · layout 宽度正常、断点却偏早 → CoreText 在「每字一个 run」的
        //     字符串上词边界识别退化，导致按字断行
        // 受设置里的「开启日志记录」控制，关着时不会输出。
        logWrapDecisionIfUseful(
            source: source,
            lineBreakOffsets: lineBreakOffsets,
            constrainedWidth: constrainedWidth,
            fontSize: fontSize,
            fontWeight: fontWeight
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

    // MARK: - 折行诊断

    // MARK: - 折行诊断

    /// 只在**真的折了**、或**文本明显超宽却没折**时打一条日志。
    ///
    /// 输出示例：
    /// ```
    /// [LyricWrap] w=366.0 layout=355.0 breaks=[21,29] "…and a↵brand↵new wagon"
    /// ```
    /// - `w`：传进来的可用宽度（应该等于容器宽 − 左右内边距）
    /// - `layout`：实际用于测量的宽度（`w` 减去安全余量）
    /// - `text`：**整段文本不折行时的真实宽度** —— 判断"该不该折"的硬指标
    /// - `breaks`：CoreText 给出的折行字符下标
    /// - 引号里的 `↵` 就是断点位置
    private static func logWrapDecisionIfUseful(
        source: String,
        lineBreakOffsets: Set<Int>,
        constrainedWidth: CGFloat?,
        fontSize: CGFloat,
        fontWeight: LyricsFontWeight
    ) {
        let hasBreaks = !lineBreakOffsets.isEmpty

        // 没折行时，只在「按估算宽度看它本该折」的情况下才报警，
        // 免得把一屏短的短行全打出来。
        var shouldLog = hasBreaks
        if !hasBreaks, let constrainedWidth, constrainedWidth > 0, fontSize > 0 {
            let estimatedWidth = CGFloat(source.count) * fontSize * 0.55
            shouldLog = estimatedWidth > constrainedWidth
        }
        guard shouldLog else { return }

        let layoutWidth: String
        if let constrainedWidth, constrainedWidth > 0 {
            layoutWidth = String(
                format: "%.1f",
                effectiveLayoutWidth(
                    source: source,
                    constrainedWidth: constrainedWidth,
                    fontSize: fontSize,
                    usesTimedRunBoundaries: true
                )
            )
        } else {
            layoutWidth = "nil"
        }

        let breaks = lineBreakOffsets.sorted()
            .map(String.init)
            .joined(separator: ",")

        // 未折行时整段文本的实际排版宽度。
        //
        // 这是判断"该不该折"的唯一硬指标 —— 比按字符数估算可靠：
        //   text < layout 却折了  → 折行器有问题
        //   text ≈ w 却折了       → 余量把预算砍过头（就是之前那个 18.3pt）
        //   text > w              → 折得理所当然
        let textWidth = String(
            format: "%.1f",
            measuredTextWidth(
                source: source,
                fontSize: fontSize,
                fontWeight: fontWeight
            )
        )

        writeDebugLog(
            "[LyricWrap] fs=\(String(format: "%.1f", fontSize))"
                + " w=\(constrainedWidth.map { String(format: "%.1f", $0) } ?? "nil")"
                + " layout=\(layoutWidth)"
                + " text=\(textWidth)"
                + " breaks=[\(breaks)]"
                + " \"\(marked(source, at: lineBreakOffsets))\""
        )
    }

    /// 整段文本（不折行）的排版宽度，用于诊断。
    private static func measuredTextWidth(
        source: String,
        fontSize: CGFloat,
        fontWeight: LyricsFontWeight
    ) -> CGFloat {
        guard !source.isEmpty, fontSize > 0 else { return 0 }
        let font = UIFont.systemFont(
            ofSize: fontSize,
            weight: fontWeight.uiKitWeight
        )
        let attributed = NSAttributedString(
            string: source,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// 在断点处插入 `↵` 便于肉眼核对。
    private static func marked(
        _ source: String,
        at offsets: Set<Int>
    ) -> String {
        guard !offsets.isEmpty else {
            return source.count > 70 ? String(source.prefix(70)) + "…" : source
        }
        var result = ""
        for (index, character) in source.enumerated() {
            if offsets.contains(index), index > 0 {
                result += "↵"
            }
            result += String(character)
        }
        return result
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
            // ⚠️ 这里曾经照抄 MeloX 的 `max(w * 0.05, fs * 0.5)` → 366 × 5% = 18.3pt。
            //
            // 那个余量在 MeloX 里有意义：它**测量**用的是带「每字一个 run」的字符串
            // （测得偏宽），而**渲染**交给 SwiftUI 的是干净的逐字 Text 拼接。
            // 余量是拿测量的虚高去补贴渲染，方向正确。
            //
            // 但本项目的移植把那一处改掉了（改成"先拼字符串、再一次性写属性"），
            // 于是**测量与渲染变成同一个字符串** —— 余量不再补贴任何东西，
            // 只是净砍掉 18.3pt 真实可用宽度。
            // 而 18.3pt ≈ 一个短词的宽度，结果就是每一行的最后一个词被挤下去：
            //   "Twenty racks a table cut from ↵ebony"（剩 ~30pt 却放不下 ebony）
            //   "Bought Mama a crib and a brand ↵new wagon"（剩 ~19pt 却放不下 new）
            //
            // 所以这里把余量降到「只够吸收舍入误差」的量级，把"放不放得下"的判断权
            // 还给真实字体度量。若实测出现长行右侧轻微溢出，用 `LyricLineFitting`
            // 的超宽缩放兜（那条路径是 MeloX 验证过的，本就是这套设计的配套件）。
            safetyMargin = max(fontSize * 0.1, 0.5)
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
