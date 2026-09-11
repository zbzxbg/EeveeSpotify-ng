import Foundation

// MARK: - 逐词时长解析与数据质量判定
//
// 两个来源的真实缺口（决定了本文件必须存在）：
//   1. `LyricsWordDto.endMs` 只有部分歌词源提供 —— Musixmatch richsync 路径
//      完全不填（只给 `o`：相对行首的起始偏移），PetitLyrics 的 token 兜底
//      分支也会丢掉。因此「词何时结束」必须能被**推断**。
//   2. 词级时间戳的质量参差不齐 —— CHANGELOG 里专门为「逐词时间戳质量太差
//      时要回退行级」修过一次。填充动画对坏时间的表现比逐词跳变更糟
//      （会卡住或倒着走），所以需要在渲染前判定。
//
// 判定门槛的取值参考（两个独立项目得出同一量级）：
//   accompanist-lyrics-ui : per-char > 200ms && word >= 1000ms 才做逐字动效
//   AMLL                  : 只对 >= 1s 且 <= 7 字符的强调词做逐 grapheme 拆分
//
// 但这里**不**照搬 200ms —— 那个门槛是给「逐字弹跳/发光」用的。快速说唱、
// 日文/中文快歌的逐词间隔本来就在 100ms 量级，按 200ms 一刀切会把这些
// 完全正常的歌词误判为坏数据。填充动画只需要拒绝「词都挤在同一个时刻」
// 这种退化数据，因此用**起始时间的中位间隔**判定。

enum WordTimingResolver {

    /// 一个词的已解析时长。
    ///
    /// - `startMs` 来自 `LyricsWordDto.startMs`，始终可信。
    /// - `endMs` 可能是推断值，`isInferred=true` 表示它来自下一个词的起始时间
    ///   或本段结束时间，而非上游明确给出。
    struct WordTiming {
        var text: String
        var startMs: Int
        var endMs: Int
        var isInferred: Bool
    }

    /// 中位词间隔下限（毫秒）。低于此值说明词级时间轴退化（多个词挤在同一时刻），
    /// 此时填充会长时间卡住不动，不如退回行级。
    ///
    /// 取 40ms 而非 200ms：40ms 已经相当于每秒 25 个词，任何语言的歌声都不可能
    /// 达到，因此只可能命中真正的退化数据，不会误伤快歌。
    static let degenerateMedianGapMs = 40

    /// 解析一行内所有词的时长。
    ///
    /// 推断链：`endMs` → 下一个词的 `startMs` → `segmentEndMs` → `startMs + 最小可见时长`。
    static func resolve(
        words: [LyricsWordDto],
        segmentEndMs: Int,
        minimumDurationMs: Int = 80
    ) -> [WordTiming] {
        guard !words.isEmpty else { return [] }

        var result: [WordTiming] = []
        result.reserveCapacity(words.count)

        for index in words.indices {
            let word = words[index]
            let start = word.startMs

            let explicit = word.endMs
            let nextStart = index + 1 < words.count ? words[index + 1].startMs : nil

            var end: Int
            var inferred: Bool

            if let explicit, explicit > start {
                end = explicit
                inferred = false
            } else if let nextStart, nextStart > start {
                end = nextStart
                inferred = true
            } else if segmentEndMs > start {
                end = segmentEndMs
                inferred = true
            } else {
                // 最后一个词且没有可用上界：给一个最小可见时长，
                // 避免零长度导致填充瞬间跳过。
                end = start + minimumDurationMs
                inferred = true
            }

            // 不允许越过后一个词的起始时间（重叠词/和声在 yrc 里真实存在，
            // 但填充只能有一个前缘，重叠部分按前者处理）。
            if let nextStart, end > nextStart, nextStart > start {
                end = nextStart
                inferred = true
            }

            result.append(
                WordTiming(
                    text: word.text,
                    startMs: start,
                    endMs: max(end, start + 1),
                    isInferred: inferred
                )
            )
        }

        return result
    }

    /// 词级时间轴质量判定。为 false 时该行降级为行级填充。
    ///
    /// 只拒绝**退化**数据，不拒绝「快速」数据：
    ///   - 有效词数 < 2            → 没有可插值的边界
    ///   - 起始时间中位间隔过小    → 词都挤在同一时刻，填充会卡住
    ///   - 解析出的时长中位数 < 1ms → 时间轴本身无意义
    static func isUsableForFill(_ timings: [WordTiming]) -> Bool {
        guard timings.count >= 2 else { return false }

        let sorted = timings.map(\.startMs).sorted()
        var gaps: [Int] = []
        for index in 1..<sorted.count {
            let gap = sorted[index] - sorted[index - 1]
            if gap > 0 { gaps.append(gap) }
        }

        // 全部起始时间相同 = 退化（PetitLyrics 的伪 wordsSynced 就是这种）。
        guard !gaps.isEmpty else { return false }

        let gapsSorted = gaps.sorted()
        let medianGap = gapsSorted[gapsSorted.count / 2]
        guard medianGap >= degenerateMedianGapMs else { return false }

        let durations = timings.map { $0.endMs - $0.startMs }.sorted()
        let medianDuration = durations[durations.count / 2]
        return medianDuration >= 1
    }

    // MARK: 逐字动效的作用范围
    //
    // 分歧点：**每个词都做位移动效，还是只给长音符？**
    // 调研到的成品一致选了「长音符才做真正的动效」：
    //   - AMLL `line.ts shouldEmphasize`：`>= 1000ms`；非 CJK 再加 2~7 字符。
    //     逐字注释写明这是「果子对辉光效果的解释是一种**强调**效果」。
    //   - Cider 2 更新日志原文：*"lift each word as it is sung and give
    //     **held words** the per-glyph bump, glow and float"* —— 同样二分。
    //   - Lyricify：光效只给 *"longer words"*。
    //   - BlurLyric：`if (contentObj.dur >= 2)` 才加特效。
    // 反过来，「每个词都大幅位移」在六份证据里**一家都没有**。

    /// 强调门槛（毫秒）。AMLL 用 1000，这里沿用。
    static let emphasizeMinDurationMs = 1000

    /// 该词是否够「长」，值得上真正的逐字动效。
    ///
    /// CJK 单字天然短，不加长度上限（AMLL 同）；
    /// 非 CJK 再加 2~7 字符的限制，避免把 "the"、"a" 这类虚词也点亮。
    static func shouldEmphasize(_ timing: WordTiming) -> Bool {
        let duration = timing.endMs - timing.startMs
        guard duration >= emphasizeMinDurationMs else { return false }

        let stripped = timing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = stripped.count
        if containsCJK(stripped) { return true }
        return count >= 2 && count <= 7
    }

    /// 是否含 CJK。范围与 AMLL 的 `isCJK` 正则一致
    /// （`[\p{Unified_Ideograph}\u0800-\u9FFC]`），覆盖汉字、假名、韩文与
    /// 扩展区，因此日文歌词也会走「不加长度上限」这一支。
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0800...0x9FFF,     // 涵盖傈僳文、天城文区、CJK 及假名
                 0x3400...0x4DBF,     // CJK 扩展 A
                 0xF900...0xFAFF,     // CJK 兼容表意文字
                 0x20000...0x2FA1F,   // CJK 扩展 B~F 与兼容补充
                 0xAC00...0xD7AF,     // 韩文音节
                 0x1100...0x11FF:     // 韩文字母
                return true
            default:
                return false
            }
        }
    }
}
