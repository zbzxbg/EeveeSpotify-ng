import Foundation

// MARK: - LyricsMarkerConfiguration
//
// 「删除歌曲标注术语」的共享配置：Genius 与网易云两个歌词源共用同一份
// 术语清单，避免两处各自维护导致漂移。
//
// sectionMarkers 匹配前会做「去音调 + 大写」归一化，所以 REFRÃO /
// refrao / Pré-Refrão 都会归一到同一 token；因此这里一律写大写。

struct LyricsMarkerConfiguration {
    let sectionMarkers: [String]
    let metadataPrefixes: [String]
    let titlePrefixPatterns: [String]
    let titleHeaderPatterns: [String]

    static let shared = LyricsMarkerConfiguration(
        sectionMarkers: [
            "INTRO(DUCAO)?",
            "VERSE", "VERSO",
            "CHORUS", "REFRAO", "ПРИПЕВ",
            "PRE[- ]?CHORUS", "PRE[- ]?REFRAO",
            "POST?[- ]?CHORUS", "POS[- ]?REFRAO",
            "BRIDGE", "PONTE",
            "HOOK", "GANCHO",
            "INTERLUDE", "INTERLUDIO",
            "SOLO", "INSTRUMENTAL", "INSTRUMENTAL\\?", "\\?INSTRUMENTAL\\?",
            "FX", "SFX",
            "OUTRO", "ENCERRAMENTO",
            "DROP",
            "BREAK(DOWN)?",
            "FADE[ ]?OUT",
            "LOOP",
            "PRE[- ]?OUTRO",
            "PRE[- ]?SAIDA",
            "SAIDA",
            "RANN", "SEIST",
            "PRE[- ]?CORO", "CORO"
        ],
        metadataPrefixes: [
            "PRODUCED BY",
            "WRITTEN BY",
            "COMPOSED BY",
            "TRANSLATED BY",
            "注释"
        ],
        titlePrefixPatterns: [
            "TEKISUTO\\s+O\\s+LETRA DE",
            "LETRA DE",
            "TEXT OF"
        ],
        titleHeaderPatterns: [
            ".+[「『].+[」』]\\s*(?:KASHI|歌詞)"
        ]
    )
}

// MARK: - LyricsMarkerFilter
//
// 判定某一行是否属于「结构标注」而非歌词正文，供 Genius / 网易云复用。
// 匹配全部基于归一化文本（trim + 去音调 + 大写），因此大小写、重音不敏感。

enum LyricsMarkerFilter {

    private static let markerConfiguration = LyricsMarkerConfiguration.shared

    /// 章节标记模式：由 sectionMarkers 拼出的 alternation。
    private static let sectionMarkerPattern: String = {
        "(?:\(markerConfiguration.sectionMarkers.joined(separator: "|")))"
    }()

    /// 制作信息头（PRODUCED BY / WRITTEN BY / 注释 等），按字面转义。
    private static let metadataMarkerPattern: String = {
        let markers = markerConfiguration.metadataPrefixes.map {
            NSRegularExpression.escapedPattern(for: $0)
        }
        return "(?:\(markers.joined(separator: "|")))"
    }()

    private static let titlePrefixPattern: String = {
        "(?:\(markerConfiguration.titlePrefixPatterns.joined(separator: "|")))"
    }()

    private static let titleHeaderPattern: String = {
        "(?:\(markerConfiguration.titleHeaderPatterns.joined(separator: "|")))"
    }()

    private static let markerNumberSuffix = "(?:\\s+(?:N[. ]?)?\\d+(?:[.]\\d+)?)?"
    private static let repeatCountSuffix = "(?:\\s+X\\d+)?"

    /// 方括号内只有符号/标点（无字母、无数字）的行：[♪] [?] [□] [—] …
    private static let bracketedSymbolLinePattern =
        "^\\[\\s*[^\\p{L}\\p{N}]+\\s*\\]$"

    /// 无括号、整行只有符号的占位行：□ ? … — 等。
    /// 排除音乐符号（♪/♫/♬/♩/♭/♯），因为它们由网易云「删除间奏符号」开关单独控制。
    private static let bareSymbolLinePattern =
        "^[^\\p{L}\\p{N}♪♫♬♩♭♯]+$"

    /// 归一化：trim + 去音调 + 大写，用于大小写/重音不敏感匹配。
    static func normalizedForMarkerMatch(_ line: String) -> String {
        return line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: nil)
            .uppercased()
    }

    /// 该行是否为结构元数据（章节标记、制作信息、标题头、占位符号等）。
    static func isNonLyricLine(_ line: String) -> Bool {
        let normalized = normalizedForMarkerMatch(line)
        guard !normalized.isEmpty else { return false }

        // 1) 方括号章节标记：[Interlude] / [Verse 1] / [Fx] / [Instrumental?] …
        if normalized ~= "^\\[\\s*\(sectionMarkerPattern)\(markerNumberSuffix)(?:\\s*[:|\\-].*)?\\s*\\]\(repeatCountSuffix)$" {
            return true
        }

        // 2) 方括号制作信息头：[Produced by X] / [Written by X] / [注释 …]
        if normalized ~= "^\\[\\s*\(metadataMarkerPattern)(?:\\s+.*)?\\s*\\]$" {
            return true
        }

        // 3) 动态标题头：[Letra de “Song”] / [Text of “Song”]
        if normalized ~= "^\\[\\s*\(titlePrefixPattern)\\s*[\"'“‘].*[\"'”’]\\s*\\]$" {
            return true
        }

        // 4) 日语/罗马音标题头：[…「…」kashi]
        if normalized ~= "^\\[\\s*\(titleHeaderPattern)\\s*\\]$" {
            return true
        }

        // 5) 圆括号章节标记：(INTRO) / (OUTRO) / (PRE-OUTRO) …（不删任意括号旁白）
        if normalized ~= "^\\(\\s*\(sectionMarkerPattern)\(markerNumberSuffix)\\s*\\)$" {
            return true
        }

        // 6) 无括号的裸章节标记：VERSO / INTERLUDE / FX …
        if normalized ~= "^\(sectionMarkerPattern)\(markerNumberSuffix)\\s*:?\\s*$" {
            return true
        }

        // 7) 标题头行：LETRA DE "…" / TEXT OF "…"
        if normalized ~= "^\(titlePrefixPattern)\\s*[\"'“‘]" {
            return true
        }

        // 8) 方括号内纯符号行：[♪] [?] [□] [—] …（保留 [I love you] 这类真歌词）
        if normalized ~= bracketedSymbolLinePattern {
            return true
        }

        // 9) 无括号、整行只有符号的占位行（方框 / 问号 / 破折号等）
        if normalized ~= bareSymbolLinePattern {
            return true
        }

        return false
    }

    /// 去除结构标注行并清理首尾空行。
    static func mapLyricsLines(_ rawLines: [String]) -> [String] {
        var lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        lines.removeAll { isNonLyricLine($0) }

        lines = Array(lines.drop(while: { $0.isEmpty }))
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        return lines
    }
}
