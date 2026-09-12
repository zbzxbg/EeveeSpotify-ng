import Foundation

// MARK: - AmllTtmlResult → LyricsDto
//
// ── 硬不变量 ──────────────────────────────────────────────────────────────
// 每一行的 `content` 必须严格等于该行 `words` 的 text 顺序拼接（trim 后）。
// LyricsWordByWord 的渲染是「把 words 拼成显示文本 + 按 range 上色」，
// 一旦两者不一致，高亮会整行错位（看起来像「逐词数据质量差」，其实是映射 bug）。
// 因此 x-translation / x-roman 这类 span 在解析阶段就已被抽走，绝不留在词序列里；
// 并且行 content 不是取自解析结果，而是**由词序列反推**，从构造上保证两者一致。
//
// ── 逐词覆盖率 ────────────────────────────────────────────────────────────
// 渲染层的 hasUsableWordLevel 阈值是「≥50% 的行有 ≥2 个词」。低于阈值时保留行级时间轴、
// 丢弃全部词级数据，让 overlay 自然回退到原生歌词滚动 —— 这比丢掉整首歌划算。
//
// ── 官方罗马音（x-roman）──────────────────────────────────────────────────
// TTML 自带的 x-roman 是人工校对的逐行罗马音，质量高于本地 toJapaneseRomaji()。
// 采用与 NetEase romalrc 相同的既有路径：在 repository 层直接替换主行文本并标记
// .romanized，让本地罗马化链路整体跳过，保证 overlay 与原生歌词行看到同一份文本。
// 只在「确实是日语歌 + 用户开了日语罗马化开关 + 官方罗马音能覆盖过半行数」时才替换，
// 对不上就整体放弃，绝不做模糊贴靠。

enum AmllLyricsMapper {

    /// 渲染层判定「词级数据可用」的阈值，与 LyricsWordByWord.hasUsableWordLevel 保持一致。
    private static let wordLevelCoverageNumerator = 5
    private static let wordLevelCoverageDenominator = 10

    private static let japaneseRomanizationKey = "ngzhwm_japaneseRomanization"

    static func makeDto(_ parsed: AmllTtmlResult) -> LyricsDto {
        var lines: [LyricsLineDto] = []
        var translations: [String] = []

        // ── 逐行：先建词序列，再由词序列反推 content ──────────────────────
        var wordLines: [[LyricsWordDto]?] = []
        for line in parsed.lines {
            let tokens = wordTokens(for: line)
            let content = tokens.map { $0.map(\.text).joined() } ?? line.primaryText
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

            // 空行（只有背景人声/翻译的行）与结构标注行不收录。
            // 注意：解析层已过滤过一轮，这里防的是「背景人声拼出来后为空」的情况。
            guard !trimmed.isEmpty else {
                wordLines.append(nil)
                continue
            }

            lines.append(
                LyricsLineDto(content: trimmed, offsetMs: line.offsetMs, words: nil)
            )
            translations.append(line.translation ?? "")
            wordLines.append(tokens)
        }

        guard !lines.isEmpty else {
            return LyricsDto(lines: [], timeSynced: true, romanization: .original)
        }

        // ── 逐词覆盖率闸门 ────────────────────────────────────────────────
        let usableWordLines = wordLines.filter { ($0?.count ?? 0) >= 2 }.count
        let wordLevelUsable = usableWordLines * wordLevelCoverageDenominator
            >= lines.count * wordLevelCoverageNumerator

        if wordLevelUsable {
            for index in lines.indices {
                lines[index].words = wordLines[index]
            }
            writeDebugLog("[AMLL] word-level coverage \(usableWordLines)/\(lines.count) — keeping words")
        } else {
            writeDebugLog(
                "[AMLL] word-level coverage \(usableWordLines)/\(lines.count) below threshold — line-synced only"
            )
        }

        // ── 罗马化状态 ────────────────────────────────────────────────────
        let contents = lines.map(\.content)
        var languageCode = contents.romanizationLanguageCode
        var romanization: LyricsRomanizationStatus = contents.canBeRomanized
            ? .canBeRomanized
            : .original

        if parsed.hasRomanization,
           let replaced = applyOfficialRomanization(to: lines, parsed: parsed, languageCode: languageCode) {
            lines = replaced
            romanization = .romanized
            languageCode = "ja"
        }

        // ── 翻译层 ────────────────────────────────────────────────────────
        // 必须与主歌词行数完全一致（渲染层按行索引取），因此每行都占位（无翻译填空串）。
        // 注意：官方罗马音替换不改变行数，翻译索引依然有效。
        let translation = translations.contains { !$0.isEmpty }
            ? LyricsTranslationDto(
                languageCode: preferredTranslationLanguageCode(parsed) ?? languageCode ?? "zh",
                lines: translations
            )
            : nil

        writeDebugLog(
            "[AMLL] mapped \(lines.count) line(s), translation=\(translation == nil ? "none" : "yes"), romanization=\(romanization)"
        )

        return LyricsDto(
            lines: lines,
            timeSynced: true,
            romanization: romanization,
            translation: translation,
            languageCode: languageCode
        )
    }

    // MARK: - 词序列

    /// 主词 + 背景人声合并成一个词序列。
    /// 返回 nil 表示该行没有可用逐词数据（退回行级）。
    ///
    /// 背景人声（ttm:role="x-bg"）与主词时间重叠，而本项目渲染层是单列单行模型，
    /// 表达不了行内子行，因此合并到行尾：`主词 (背景人声)`。内容不丢、不变量成立、
    /// 高亮不错位；代价是背景人声从「同时」退化为「顺序」点亮。
    private static func wordTokens(for line: AmllTtmlLine) -> [LyricsWordDto]? {
        var tokens: [LyricsWordDto] = []
        let background = line.backgroundVocal
        let backgroundSyllables = background?.syllables ?? []

        if let background, background.isBeforePrimary, !backgroundSyllables.isEmpty {
            tokens.append(contentsOf: parenthesized(backgroundSyllables))
            if !line.syllables.isEmpty, !endsWithWhitespace(tokens) {
                tokens.append(LyricsWordDto(text: " ", startMs: line.syllables[0].startMs))
            }
        }

        for syllable in line.syllables where !syllable.text.isEmpty {
            tokens.append(
                LyricsWordDto(
                    text: syllable.text,
                    startMs: syllable.startMs,
                    endMs: syllable.endMs
                )
            )
        }

        if let background, !background.isBeforePrimary, !backgroundSyllables.isEmpty {
            if !tokens.isEmpty, !endsWithWhitespace(tokens) {
                tokens.append(
                    LyricsWordDto(text: " ", startMs: backgroundSyllables[0].startMs)
                )
            }
            tokens.append(contentsOf: parenthesized(backgroundSyllables))
        }

        guard !tokens.isEmpty else { return nil }

        // 不变量自检：拼出来的文本必须与解析出的行文本一致，否则宁可退回行级，
        // 也不要带着错位的词级数据去喂渲染层。
        let joined = tokens.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = expectedText(for: line)
        guard joined == expected else {
            writeDebugLog(
                "[AMLL] content mismatch — tokens=\"\(joined.prefix(60))\" expected=\"\(expected.prefix(60))\" — dropping words for this line"
            )
            return nil
        }

        return tokens
    }

    /// 该行「应该」长什么样（主词 + 背景人声按位置拼接，trim 后）。
    private static func expectedText(for line: AmllTtmlLine) -> String {
        var text = ""
        let backgroundSyllables = line.backgroundVocal?.syllables ?? []

        if let background = line.backgroundVocal,
           background.isBeforePrimary, !backgroundSyllables.isEmpty {
            text += "(\(backgroundSyllables.map(\.text).joined()))"
            if !line.syllables.isEmpty { text += " " }
        }

        text += line.syllables.map(\.text).joined()

        if let background = line.backgroundVocal,
           !background.isBeforePrimary, !backgroundSyllables.isEmpty {
            if !text.isEmpty, !text.hasSuffix(" ") { text += " " }
            text += "(\(backgroundSyllables.map(\.text).joined()))"
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parenthesized(_ syllables: [AmllTtmlSyllable]) -> [LyricsWordDto] {
        guard let first = syllables.first, let last = syllables.last else { return [] }
        var tokens: [LyricsWordDto] = [
            LyricsWordDto(text: "(", startMs: first.startMs, endMs: first.startMs)
        ]
        tokens.append(contentsOf: syllables.map {
            LyricsWordDto(text: $0.text, startMs: $0.startMs, endMs: $0.endMs)
        })
        tokens.append(LyricsWordDto(text: ")", startMs: last.endMs, endMs: last.endMs))
        return tokens
    }

    private static func endsWithWhitespace(_ tokens: [LyricsWordDto]) -> Bool {
        tokens.last.map { $0.text.last?.isWhitespace ?? false } ?? false
    }

    // MARK: - 官方罗马音

    /// 用官方 x-roman 替换主行文本。返回 nil 表示不适用（保持原文 + 本地罗马化）。
    private static func applyOfficialRomanization(
        to lines: [LyricsLineDto],
        parsed: AmllTtmlResult,
        languageCode: String?
    ) -> [LyricsLineDto]? {
        guard UserDefaults.standard.bool(forKey: japaneseRomanizationKey) else {
            writeDebugLog("[AMLL] official romanization present, but Japanese romanization is off — keeping original")
            return nil
        }

        guard isJapanese(parsed: parsed, languageCode: languageCode) else {
            writeDebugLog("[AMLL] official romanization present, but song is not Japanese — keeping original")
            return nil
        }

        // 逐行顺序配对：原文行（解析层的 lines）与官方罗马音一一对齐。
        // 解析层的 lines 与 mapper 的 lines 顺序一致，只是 mapper 可能少几行空行，
        // 因此按「原文非空」过滤出配对序列。
        let pairs = parsed.lines
            .filter { !$0.primaryText.isEmpty }
            .map { ($0.primaryText, $0.romanization ?? "") }

        guard pairs.count == lines.count else {
            writeDebugLog(
                "[AMLL] official romanization line count mismatch (\(pairs.count) vs \(lines.count)) — discarding"
            )
            return nil
        }

        var replaced: [LyricsLineDto] = []
        replaced.reserveCapacity(lines.count)
        var covered = 0

        for (index, line) in lines.enumerated() {
            let romanization = pairs[index].1
            guard !romanization.isEmpty else {
                replaced.append(line)
                continue
            }
            covered += 1
            replaced.append(
                LyricsLineDto(content: romanization, offsetMs: line.offsetMs, words: nil)
            )
        }

        // 有过半的行拿到官方罗马音才采用（个别行缺 x-roman 可以接受，整首对不上就放弃）。
        guard covered > 0, covered * 2 >= lines.count else {
            writeDebugLog("[AMLL] official romanization covers only \(covered)/\(lines.count) line(s) — discarding")
            return nil
        }

        writeDebugLog("[AMLL] applied official romanization to \(covered)/\(lines.count) line(s)")

        // 官方罗马音是行级的、没有词级时间轴，替换后词级文本已不对应，整体丢弃。
        return replaced
    }

    private static func isJapanese(parsed: AmllTtmlResult, languageCode: String?) -> Bool {
        if let language = parsed.language?.lowercased(), language.hasPrefix("ja") {
            return true
        }
        if languageCode == "ja" { return true }
        // 兜底：原文出现假名即认定日语（汉字归属有歧义，不作为依据）。
        return parsed.lines.contains { line in
            line.primaryText.unicodeScalars.contains { scalar in
                switch scalar.value {
                case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                    return true
                default:
                    return false
                }
            }
        }
    }

    private static func preferredTranslationLanguageCode(_ parsed: AmllTtmlResult) -> String? {
        let languages = parsed.lines.compactMap { $0.translationLanguage }
        guard !languages.isEmpty else { return nil }

        let counts = languages.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        guard let dominant = counts.max(by: { $0.value < $1.value })?.key else { return nil }

        // 归一到短码：zh-Hans-CN → zh。
        let lowercased = dominant.lowercased()
        if lowercased.hasPrefix("zh") { return "zh" }
        if lowercased.hasPrefix("ja") { return "ja" }
        if lowercased.hasPrefix("ko") { return "ko" }
        if lowercased.hasPrefix("en") { return "en" }
        return dominant
    }
}
