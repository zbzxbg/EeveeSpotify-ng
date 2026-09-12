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
                text: line.content,
                syllables: syllables,
                romanization: nil,
                romanizationSyllables: [],
                translation: Self.normalized(translationText),
                agent: nil,
                backgroundVocal: nil
            )
        }
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
            // 空白 token（部分来源会带纯空格词）不参与高亮。
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let wordStart = TimeInterval(word.startMs) / 1000

            let wordEnd: TimeInterval?
            if let endMs = word.endMs {
                wordEnd = TimeInterval(endMs) / 1000
            } else if index + 1 < words.count {
                wordEnd = TimeInterval(words[index + 1].startMs) / 1000
            } else {
                wordEnd = nextStartTime
            }

            guard let wordEnd, wordEnd > wordStart else {
                // 单个词的时间轴坏掉就整体放弃，避免产出半截时间轴
                // 让渲染层算出一堆零长度音节。
                return []
            }

            result.append(
                LyricSyllable(
                    text: word.text,
                    startTime: wordStart,
                    endTime: wordEnd
                )
            )
        }

        // 至少要两个词才算「真逐字」；只有一个词的时间轴等价于行级。
        return result.count >= 2 ? result : []
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
