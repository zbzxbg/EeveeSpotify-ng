import Foundation

// 本项目新增（非 MeloX 移植件）：把仓库层现有的 `LyricsDto` 转成 MeloX 渲染层
// 消费的 `[LyricLine]`。
//
// 为什么不直接用 MeloX 的数据层：MeloX 的 `LyricsService` / `LyricsStore` /
// `LyricSourceMerger` 绑定它自己的取词与缓存体系，而本项目的 Repository 层已经
// 覆盖更多来源（网易 yrc / Musixmatch richsync / Spicy / AMLL / Petit / LRCLIB /
// Genius），没必要替换。这里只做模型适配。

extension LyricsDto {

    /// 转成 Apple Music 风格渲染层使用的行模型。
    ///
    /// 时间语义：
    ///   - 有词级时间轴的行 → `.precise`，并给出 `duration`
    ///   - 只有行级时间的行 → `.lineSynchronized`，`duration` 取「下一行起始 − 本行起始」
    ///     （末行用 `LyricVocalDurationEstimator` 估算），供渲染层按需拆「伪逐字」
    func toAppleMusicLyricLines() -> [LyricLine] {
        let sorted = lines
            .filter { $0.offsetMs != nil }
            .sorted { ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0) }

        guard !sorted.isEmpty else { return [] }

        let translationLines = translation?.lines ?? []

        return sorted.enumerated().map { index, line in
            let startMs = line.offsetMs ?? 0
            let startTime = TimeInterval(startMs) / 1000

            // 下一行的起点 → 本行的显示时长。末行没有下一行可用，退回估算。
            let nextStartTime: TimeInterval? = index + 1 < sorted.count
                ? TimeInterval(sorted[index + 1].offsetMs ?? startMs) / 1000
                : nil

            let syllables = Self.syllables(
                for: line,
                startTime: startTime,
                nextStartTime: nextStartTime
            )
            let isPrecise = !syllables.isEmpty

            let duration: TimeInterval?
            if isPrecise {
                // 精确行以作者标注的最后一个音节结束为准。
                duration = max((syllables.last?.endTime ?? startTime) - startTime, 0)
            } else if let nextStartTime {
                duration = max(nextStartTime - startTime, 0)
            } else {
                duration = LyricVocalDurationEstimator.estimatedDuration(for: line.content)
            }

            let translationText: String? = index < translationLines.count
                ? translationLines[index]
                : nil

            return LyricLine(
                id: Self.lineID(index: index, startMs: startMs),
                time: startTime,
                duration: duration,
                timingKind: isPrecise ? .precise : .lineSynchronized,
                // ★ 必须用 `line.content`，**不要**把 words 拼回来当行文本。
                //
                // 原因：SpicyLyrics 的解析器会给非首词补一个前导空格
                // （`SpicyLyricsRepository.swift` 里 `wordText = " " + syllableText`），
                // 而 `content` 已经是按同一规则拼好的。若这里再拼一次，文本就比
                // 逐字时间轴多出一批空格字符，填充前沿会整体漂移。
                // 用 content 才能保证「文本」与「音节时间轴」严格对应。
                text: line.content,
                syllables: syllables,
                romanization: nil,
                romanizationSyllables: [],
                translation: Self.normalized(translationText),
                agent: nil,
                backgroundVocal: Self.backgroundVocal(for: line)
            )
        }
    }

    /// 背景人声/副唱 → MeloX 的背景人声模型。
    ///
    /// 位置语义要把仓库层的 `isBeforePrimary` 翻成渲染层的
    /// `.beforePrimary` / `.afterPrimary` —— 名字一样但归属类型不同，别直接传。
    private static func backgroundVocal(
        for line: LyricsLineDto
    ) -> LyricBackgroundVocal? {
        guard let background = line.backgroundVocal,
              !background.isEmpty else { return nil }

        let syllables = background.syllables.compactMap { word -> LyricSyllable? in
            guard !word.text.isEmpty else { return nil }
            let start = TimeInterval(word.startMs) / 1000
            // 副唱允许零时长：括号之类的标记不该有填充动画。
            let end = word.endMs.map { TimeInterval($0) / 1000 } ?? start
            guard end >= start else { return nil }
            return LyricSyllable(text: word.text, startTime: start, endTime: end)
        }
        guard !syllables.isEmpty else { return nil }

        let text = background.text
        guard !text.isEmpty else { return nil }

        return LyricBackgroundVocal(
            time: syllables[0].startTime,
            duration: max(
                (syllables.last?.endTime ?? syllables[0].startTime)
                    - syllables[0].startTime,
                0
            ),
            text: text,
            syllables: syllables,
            translation: nil,
            position: background.isBeforePrimary
                ? .beforePrimary
                : .afterPrimary
        )
    }

    // MARK: - 私有

    /// 词级时间轴 → 音节数组。
    ///
    /// 只用**首尾都拿得到**的词构建：`endMs` 缺失的词会借用「下一个词的 startMs」，
    /// 借不到（末词）就用行时长兜底；两者都没有时返回空数组，
    /// 让调用方退回 `.lineSynchronized`（宁可整行同步，也不要编造时间轴）。
    private static func syllables(
        for line: LyricsLineDto,
        startTime: TimeInterval,
        nextStartTime: TimeInterval?
    ) -> [LyricSyllable] {
        guard let words = line.words, !words.isEmpty else { return [] }

        var result: [LyricSyllable] = []
        result.reserveCapacity(words.count)

        for (index, word) in words.enumerated() {
            // ⚠️ 这里**不能**跳过纯空白 token。
            //
            // 音节列表会被渲染层拼回行文本（`TimedLyricTextBuilder` 用
            // `syllables.map(\.text).joined()`），而 `line.content` 里那个空格是存在的。
            // 一旦这里把空格丢掉，后续所有词的字符区间都会**前移一位**，
            // 填充前沿就会整体错位。空白本身在渲染时会被跳过（渲染器只处理
            // 非空白 run），所以留着它没有任何副作用。
            guard !word.text.isEmpty else { continue }

            let wordStart = TimeInterval(word.startMs) / 1000

            let wordEnd: TimeInterval?
            if let endMs = word.endMs {
                wordEnd = TimeInterval(endMs) / 1000
            } else if index + 1 < words.count {
                wordEnd = TimeInterval(words[index + 1].startMs) / 1000
            } else {
                wordEnd = nextStartTime
            }

            guard let wordEnd, wordEnd >= wordStart else {
                // 时间戳反了（end < start）才是真坏数据，丢这一个词即可。
                //
                // 曾经这里写的是 `wordEnd > wordStart` 并把整行作废，结果是：
                // AMLL 故意给括号/间隔标记零时长，任何带背景人声的行都会整行
                // 退回行级（表现为「带括号的行不逐词」）。零时长在渲染上是安全的 ——
                // `LyricHighlightRevealProgress` 有 `guard duration > 0 else { return 1 }`，
                // 零时长音节会瞬间填满并保持，正是括号想要的静态效果。
                continue
            }

            result.append(
                LyricSyllable(
                    text: word.text,
                    startTime: wordStart,
                    endTime: wordEnd
                )
            )
        }

        // 至少要有一个**真正占时长**的音节才值得走精确时间轴；
        // 全零时长的行等价于行级，交给调用方退回。
        //
        // 曾经这里要求 count >= 2，于是「单字行」（比如独立一句 "ah"）也被降级成行级，
        // 那是没必要的：单字行同样能正常填充。
        guard result.contains(where: { $0.endTime > $0.startTime }) else {
            return []
        }
        return result
    }

    private static func lineID(index: Int, startMs: Int) -> String {
        "lyric-\(index)-\(startMs)"
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
