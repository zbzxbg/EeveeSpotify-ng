import Foundation

// MARK: - AMLL 歌词解析
//
// 把 TTML 正文解析成与项目既有模型对齐的中间结构（LyricsDto / LyricsLineDto / LyricsWordDto）。
//
// ── 转换规则 ──────────────────────────────────────────────────────────────
// <p begin/end itunes:key>          → LyricsLineDto（offsetMs = p.begin，行级时间以此为准）
// <p> 内有序的计时 <span>           → LyricsWordDto（startMs/endMs）
// <p> 内 span 之间的空白文本节点    → 并入前一个词的 text（承载英文词间空格）
// <p> 内其它文本                    → 同样作为一个词（无时间）
// ttm:role="x-translation"          → 抽走，成为 LyricsTranslationDto.lines[行索引]
// ttm:role="x-roman"                → 抽走，成为行级官方罗马音
// ttm:role="x-bg"                   → 抽走，合并到行尾（本文件的 v1 策略，见下）
// iTunesMetadata 的 <text for="L1"> → 侧挂翻译/音译，按 itunes:key 关联
// body dur / 末行 end               → 交给 repository 做身份复核
//
// ── x-bg（背景人声）的处理 ────────────────────────────────────────────────
// 背景人声在 TTML 里是嵌在同一个 <p> 内的独立计时子树，和主词时间重叠（对唱/和声）。
// 本项目的渲染层是「单列单行」模型（Spotify 原生歌词表格 + LyricsWordByWord overlay），
// 表达不了行内子行，因此 v1 采用**合并到行尾**：
//     content = "主词文本 (背景人声文本)"
// 背景词作为词条追加在末尾，时间保持原值。这样内容不丢、content == words 拼接 的不变量成立、
// 高亮不错位；代价是背景人声从「同时」退化为「顺序」点亮。
// 同一 <p> 里的 x-translation 只取 <p> 直接子级的那个（背景人声内部的翻译优先级更低）。

struct AmllTtmlSyllable {
    var text: String
    var startMs: Int
    var endMs: Int
}

struct AmllTtmlBackgroundVocal {
    var text: String
    var syllables: [AmllTtmlSyllable]
    var translation: String?
    /// true = 背景人声出现在主词之前（用于决定拼到行首还是行尾）。
    var isBeforePrimary: Bool
}

struct AmllTtmlLine {
    var key: String?
    /// 行级时间（毫秒），来自 <p begin>。
    var offsetMs: Int
    var endMs: Int?
    /// 主词（含空白词），排除 x-translation / x-roman / x-bg。
    var syllables: [AmllTtmlSyllable]
    /// 纯文本（无计时 span 时的兜底）。
    var plainText: String
    var translation: String?
    var translationLanguage: String?
    /// 官方行级罗马音/音译。
    var romanization: String?
    var backgroundVocal: AmllTtmlBackgroundVocal?
    var agent: String?

    /// 主词拼出的行文本（已 trim）。
    var primaryText: String {
        let joined = syllables.isEmpty ? plainText : syllables.map(\.text).joined()
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AmllTtmlResult {
    var lines: [AmllTtmlLine]
    /// <tt xml:lang>
    var language: String?
    /// <body dur>（毫秒）。注意这是「最后一个歌词时间戳」，不等于音频时长。
    var declaredDurationMs: Int?
    /// 所有行的最大 end（毫秒），用于身份复核。
    var lastLineEndMs: Int?
    var title: String?
    var artists: String?
    var album: String?
    /// <amll:meta key="spotifyId"> 全部取值，用于校验「这个文件确实登记了本曲的 Spotify ID」。
    var spotifyIds: [String]
    var ncmMusicIds: [String]
    var authorLogin: String?

    /// 是否含官方罗马音/音译。
    var hasRomanization: Bool {
        lines.contains { !($0.romanization ?? "").isEmpty }
    }
}

enum AmllTtmlParser {

    /// 解析 TTML 正文。输入为空、XML 非法、或没有任何有效歌词行时抛错。
    static func parse(_ source: String) throws -> AmllTtmlResult {
        guard !source.isEmpty else { throw LyricsError.decodingError }
        guard let root = AmllTtmlDocument.parse(source) else {
            writeDebugLog("[AMLL] XMLParser failed — malformed TTML")
            throw LyricsError.decodingError
        }

        let metadata = parseMetadata(in: root)
        let sidecarTranslations = parseSidecar(named: "translation", in: root)
        let sidecarTransliterations = parseSidecar(named: "transliteration", in: root)

        let paragraphNodes = root.descendants { $0.localName == "p" }
        guard !paragraphNodes.isEmpty else {
            writeDebugLog("[AMLL] no <p> element in TTML")
            throw LyricsError.noSuchSong
        }

        var parsed: [AmllTtmlLine] = []
        for node in paragraphNodes {
            guard let line = parseLine(
                node,
                translations: sidecarTranslations,
                transliterations: sidecarTransliterations
            ) else { continue }
            // 空行（含只有背景人声/翻译的行）与结构标注行不要。
            guard !line.primaryText.isEmpty else { continue }
            guard !LyricsMarkerFilter.isNonLyricLine(line.primaryText) else { continue }
            parsed.append(line)
        }

        guard !parsed.isEmpty else {
            writeDebugLog("[AMLL] TTML parsed but no usable lyric line (paragraphs=\(paragraphNodes.count))")
            throw LyricsError.noSuchSong
        }

        let sorted = parsed.sorted { $0.offsetMs < $1.offsetMs }
        let lastEnd = sorted.compactMap { $0.endMs }.max()

        return AmllTtmlResult(
            lines: sorted,
            language: root.attribute("lang"),
            declaredDurationMs: root.descendants { $0.localName == "body" }
                .first
                .flatMap { parseTimeMs($0.attribute("dur")) },
            lastLineEndMs: lastEnd,
            title: metadata.title,
            artists: metadata.artists,
            album: metadata.album,
            spotifyIds: metadata.spotifyIds,
            ncmMusicIds: metadata.ncmMusicIds,
            authorLogin: metadata.authorLogin
        )
    }

    // MARK: - 元数据

    private struct Metadata {
        var title: String?
        var artists: String?
        var album: String?
        var spotifyIds: [String] = []
        var ncmMusicIds: [String] = []
        var authorLogin: String?
    }

    private static func parseMetadata(in root: AmllTtmlNode) -> Metadata {
        var metadata = Metadata()
        var artistValues: [String] = []

        for node in root.descendants(where: { $0.localName == "meta" }) {
            guard let key = node.attribute("key"),
                  let value = node.attribute("value")?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }

            switch key {
            case "musicName": metadata.title = metadata.title ?? value
            case "artists": artistValues.append(value)
            case "album": metadata.album = metadata.album ?? value
            case "spotifyId": metadata.spotifyIds.append(value)
            case "ncmMusicId": metadata.ncmMusicIds.append(value)
            case "ttmlAuthorGithubLogin": metadata.authorLogin = metadata.authorLogin ?? value
            default: break
            }
        }

        metadata.artists = artistValues.isEmpty ? nil : artistValues.joined(separator: ", ")
        return metadata
    }

    /// 解析 <iTunesMetadata> 下的侧挂翻译/音译：<text for="L1">…</text>。
    /// 同一 key 可能有多语言，全部收下，取值时按语言优先级挑。
    private static func parseSidecar(
        named containerName: String,
        in root: AmllTtmlNode
    ) -> [String: [(language: String?, text: String)]] {
        var result: [String: [(language: String?, text: String)]] = [:]

        for container in root.descendants(where: { $0.localName == containerName }) {
            let inheritedLanguage = container.attribute("lang")
            for textNode in container.descendants(where: { $0.localName == "text" }) {
                guard let key = textNode.attribute("for") else { continue }
                let syllables = parseTimedSpans(in: textNode)
                let raw = syllables.isEmpty
                    ? textNode.text(excludingRoles: ["x-bg"])
                    : syllables.map(\.text).joined()
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                result[key, default: []].append(
                    (textNode.attribute("lang") ?? inheritedLanguage, text)
                )
            }
        }

        return result
    }

    // MARK: - 单行解析

    private static func parseLine(
        _ node: AmllTtmlNode,
        translations: [String: [(language: String?, text: String)]],
        transliterations: [String: [(language: String?, text: String)]]
    ) -> AmllTtmlLine? {
        guard let startMs = parseTimeMs(node.attribute("begin")) else { return nil }
        let endMs = parseTimeMs(node.attribute("end"))
        if let endMs, endMs < startMs {
            writeDebugLog("[AMLL] dropped line with end < begin (\(startMs)ms > \(endMs)ms)")
            return nil
        }

        let syllables = parseTimedSpans(in: node)
        let plainText = node
            .text(excludingRoles: ["x-translation", "x-roman", "x-bg"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let key = node.attribute("key")

        // 行内翻译优先于侧挂；行内的只认 <p> 直接子级，避免误取背景人声内部的翻译。
        let inlineTranslation = preferredAuxiliary(
            role: "x-translation",
            in: node,
            includeNested: false
        )
        let sidecarTranslation = key.flatMap { preferredTrack(in: translations[$0] ?? []) }

        let inlineRomanization = preferredAuxiliary(
            role: "x-roman",
            in: node,
            includeNested: false
        )
        let sidecarRomanization = key.flatMap { preferredTrack(in: transliterations[$0] ?? []) }

        let backgroundVocal = parseBackgroundVocal(in: node)

        let translationLanguage = inlineTranslation?.language ?? sidecarTranslation?.language

        return AmllTtmlLine(
            key: key,
            offsetMs: startMs,
            endMs: endMs,
            syllables: syllables,
            plainText: plainText,
            translation: normalized(inlineTranslation?.text ?? sidecarTranslation?.text),
            translationLanguage: translationLanguage,
            romanization: normalized(inlineRomanization?.text ?? sidecarRomanization?.text),
            backgroundVocal: backgroundVocal,
            agent: node.attribute("agent")
        )
    }

    /// 收集 <p> 内有序的计时词，并把 span 之间的纯空白文本节点并入前一个词。
    ///
    /// 空白并入是必须的：TTML 里 `</span> <span>` 之间的空格是真实文本节点，
    /// 英文歌词靠它承载词间空格。剔掉它会导致行文本被拼成 "Yousaid"。
    private static func parseTimedSpans(in parent: AmllTtmlNode) -> [AmllTtmlSyllable] {
        var result: [AmllTtmlSyllable] = []
        let contents = parent.contents

        for index in contents.indices {
            guard case .child(let span) = contents[index],
                  span.localName == "span",
                  !span.hasRole("x-translation"),
                  !span.hasRole("x-roman"),
                  !span.hasRole("x-bg"),
                  let startMs = parseTimeMs(span.attribute("begin")),
                  let endMs = parseTimeMs(span.attribute("end")),
                  endMs >= startMs else { continue }

            var text = span.text(excludingRoles: ["x-translation", "x-roman", "x-bg"])

            // 紧随其后的纯空白文本节点 → 并入本词（换行不算词间空格）。
            if index + 1 < contents.count,
               case .text(let separator) = contents[index + 1],
               !separator.contains("\n"),
               separator.allSatisfy(\.isWhitespace) {
                text += separator
            }

            guard !text.isEmpty else { continue }
            result.append(AmllTtmlSyllable(text: text, startMs: startMs, endMs: endMs))
        }

        return result
    }

    /// 解析背景人声子树。v1 只负责把内容取出来，拼到行尾的决策在 mapper 里。
    private static func parseBackgroundVocal(in node: AmllTtmlNode) -> AmllTtmlBackgroundVocal? {
        let entries = node.contents.enumerated().compactMap {
            index, content -> (index: Int, node: AmllTtmlNode)? in
            guard case .child(let child) = content,
                  child.localName == "span",
                  child.hasRole("x-bg") else { return nil }
            return (index, child)
        }
        guard let first = entries.first else { return nil }

        let syllables = entries.flatMap { parseTimedSpans(in: $0.node) }
        let rawText = syllables.isEmpty
            ? entries.map { $0.node.text(excludingRoles: ["x-translation", "x-roman"]) }.joined()
            : syllables.map(\.text).joined()
        guard let text = normalized(rawText) else { return nil }

        // 背景人声内部的翻译（只在 <p> 直接子级没有翻译时才会被用到，这里先存下）。
        let translation = entries
            .compactMap { preferredAuxiliary(role: "x-translation", in: $0.node, includeNested: true)?.text }
            .first

        // 位置：背景人声出现在第一个「主词 span」之前还是之后。
        let firstPrimaryIndex = node.contents.firstIndex { content in
            guard case .child(let child) = content, child.localName == "span" else { return false }
            return !child.hasRole("x-translation")
                && !child.hasRole("x-roman")
                && !child.hasRole("x-bg")
        }
        let isBeforePrimary = firstPrimaryIndex.map { first.index < $0 } ?? false

        return AmllTtmlBackgroundVocal(
            text: text,
            syllables: syllables,
            translation: normalized(translation),
            isBeforePrimary: isBeforePrimary
        )
    }

    // MARK: - 辅助轨道取值

    private static func preferredAuxiliary(
        role: String,
        in node: AmllTtmlNode,
        includeNested: Bool
    ) -> (language: String?, text: String)? {
        let candidates: [AmllTtmlNode]
        if includeNested {
            candidates = node.descendants {
                $0.localName == "span" && $0.hasRole(role)
            }
        } else {
            candidates = node.children.filter {
                $0.localName == "span" && $0.hasRole(role)
            }
        }

        let tracks = candidates.compactMap { candidate -> (language: String?, text: String)? in
            let text = candidate.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (candidate.attribute("lang"), text)
        }
        return preferredTrack(in: tracks)
    }

    /// 同一行/同一 key 可能挂多语言翻译，按「简体中文 → 其他中文 → 英文 → 其他」挑一个。
    private static func preferredTrack<T>(
        in tracks: [(language: String?, text: T)]
    ) -> (language: String?, text: T)? {
        tracks.min { languagePriority($0.language) < languagePriority($1.language) }
    }

    private static func languagePriority(_ language: String?) -> Int {
        let value = language?.lowercased() ?? ""
        if value.contains("zh-hans") || value.contains("zh_cn") || value.contains("zh-cn") {
            return 0
        }
        if value == "zh" || value.hasPrefix("zh-") { return 1 }
        if value.hasPrefix("en") { return 2 }
        return 3
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 时间解析

    /// 解析 TTML 时间值，返回毫秒。支持：
    ///   `12.3s` / `500ms`  —— 带单位
    ///   `1:02.189`         —— MM:SS.fff
    ///   `1:02:03.456`      —— HH:MM:SS.fff
    ///   `12.345`           —— 裸秒数
    /// 统一走 Double 再 rounded()，避免 Float 精度把 34.010 算成 34009。
    static func parseTimeMs(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasSuffix("ms") {
            guard let ms = Double(value.dropLast(2)) else { return nil }
            return Int(ms.rounded())
        }
        if value.hasSuffix("s") {
            guard let seconds = Double(value.dropLast()) else { return nil }
            return Int((seconds * 1000).rounded())
        }

        let parts = value.split(separator: ":")
        guard !parts.isEmpty else { return nil }

        if parts.count == 1 {
            guard let seconds = Double(parts[0]) else { return nil }
            return Int((seconds * 1000).rounded())
        }

        guard let seconds = Double(parts[parts.count - 1]),
              let minutes = Double(parts[parts.count - 2]) else { return nil }
        let hours = parts.count >= 3 ? (Double(parts[parts.count - 3]) ?? 0) : 0

        return Int(((hours * 3600 + minutes * 60 + seconds) * 1000).rounded())
    }
}
