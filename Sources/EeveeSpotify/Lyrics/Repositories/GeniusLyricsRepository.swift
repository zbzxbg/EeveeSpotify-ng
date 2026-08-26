import Foundation

class GeniusLyricsRepository: LyricsRepository {
    private let jsonDecoder: JSONDecoder
    private let apiUrl = "https://api.genius.com"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "X-Genius-iOS-Version": "6.21.0",
            "X-Genius-Logged-Out": "true",
            "User-Agent": "Genius/1109 \(URLSessionHelper.CFNetworkVersion) \(URLSessionHelper.DarwinVersion)"
        ]

        session = URLSession(configuration: configuration)

        jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    private func perform(
        _ path: String,
        query: [String:Any] = [:]
    ) throws -> GeniusDataResponse? {
        var stringUrl = "\(apiUrl)\(path)"

        if !query.isEmpty {
            let queryString = query.queryString
            stringUrl += "?\(queryString)"
        }

        let request = URLRequest(url: URL(string: stringUrl)!)

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?

        let task = session.dataTask(with: request) { response, _, err in
            error = err
            data = response
            semaphore.signal()
        }

        task.resume()

        // Bound every request so a hung Genius connection cannot stall lyrics
        // loading forever (and, with candidate fallback, never yields lyrics).
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            task.cancel()
            throw LyricsError.unknownError
        }

        if let error = error {
            throw error
        }

        guard let data = data,
              let rootResponse = try? jsonDecoder.decode(GeniusRootResponse.self, from: data) else {
            throw LyricsError.decodingError
        }
        return rootResponse.response
    }

    //

    private func searchSong(_ query: String) throws -> [GeniusHit] {
        let data = try perform("/search/song", query: ["q": query])

        guard case .sections(let sectionsResponse) = data else {
            throw LyricsError.decodingError
        }

        // Genius may return more than one section. Do not discard hits from later sections.
        return sectionsResponse.sections.flatMap(\.hits)
    }

    private func getSongInfo(_ songId: Int) throws -> GeniusSong {
        let data = try perform("/songs/\(songId)", query: ["text_format": "plain"])

        guard case .song(let songResponse) = data else {
            throw LyricsError.decodingError
        }

        return songResponse.song
    }

    //

    /// 上游思路：标题子串命中就取第一个命中的，否则取第一个结果（信任 Genius 相关度）。
    private func mostRelevantHitResult(
        hits: [GeniusHit],
        strippedTitle: String
    ) -> GeniusHitResult {
        let results = hits.map { $0.result }
        let matchingByTitle = results.filter {
            $0.title.containsInsensitive(strippedTitle)
        }
        if matchingByTitle.isEmpty {
            return results.first!
        }
        return matchingByTitle.first!
    }

    // MARK: - Non-lyric line filtering

    private static let markerConfiguration = GeniusLyricsMarkerConfiguration.shared

    /// Marker patterns are matched AFTER diacritic folding + uppercasing,
    /// so REFRÃO / REFRAO / refrão / Pré-Refrão normalize to the same token.
    private static let sectionMarkerPattern: String = {
        "(?:\(markerConfiguration.sectionMarkers.joined(separator: "|")))"
    }()

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

    /// Trims, strips diacritics, uppercases — for case/accent-insensitive matching.
    private static func normalizedForMarkerMatch(_ line: String) -> String {
        return line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: nil)
            .uppercased()
    }

    /// True if the line is structural metadata rather than actual lyric content:
    /// recognized bracketed tags, parenthesized section markers, bare section-marker
    /// lines, or `Letra de "..."` / `Text of "..."` style headers.
    static func isNonLyricLine(_ line: String) -> Bool {
        let normalized = normalizedForMarkerMatch(line)
        guard !normalized.isEmpty else { return false }

        // Only remove bracketed section markers, not every bracketed lyric line.
        // This preserves real lyrics such as `[I love you]`.
        if normalized ~= "^\\[\\s*\(GeniusLyricsRepository.sectionMarkerPattern)\(GeniusLyricsRepository.markerNumberSuffix)(?:\\s*[:|\\-].*)?\\s*\\]\(GeniusLyricsRepository.repeatCountSuffix)$" {
            return true
        }

        // Common Genius metadata headers.
        if normalized ~= "^\\[\\s*\(GeniusLyricsRepository.metadataMarkerPattern)(?:\\s+.*)?\\s*\\]$" {
            return true
        }

        // Dynamic Genius title headers, e.g. [Letra de “Song Title”].
        if normalized ~= "^\\[\\s*\(GeniusLyricsRepository.titlePrefixPattern)\\s*[\"'“‘].*[\"'”’]\\s*\\]$" {
            return true
        }

        // Japanese or romanized title headers, e.g. [Hanabasami Kyou「Under」kashi].
        if normalized ~= "^\\[\\s*\(GeniusLyricsRepository.titleHeaderPattern)\\s*\\]$" {
            return true
        }

        // (Structural marker) only — NOT arbitrary parenthesized ad-libs,
        // e.g. (INTRO), (LOOP), (PRE-OUTRO), (OUTRO), (PRE-SAIDA), (SAIDA)
        if normalized ~= "^\\(\\s*\(GeniusLyricsRepository.sectionMarkerPattern)\(GeniusLyricsRepository.markerNumberSuffix)\\s*\\)$" {
            return true
        }

        // Bare marker with no brackets at all, e.g. a standalone "VERSO" line
        if normalized ~= "^\(GeniusLyricsRepository.sectionMarkerPattern)\(GeniusLyricsRepository.markerNumberSuffix)\\s*:?\\s*$" {
            return true
        }

        // Header lines: LETRA DE "..." / TEKISUTO O LETRA DE "..." / TEXT OF "..."
        if normalized ~= "^\(GeniusLyricsRepository.titlePrefixPattern)\\s*[\"'“‘]" {
            return true
        }

        return false
    }

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

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        writeDebugLog("[Genius] Fetching lyrics for \"\(query.title)\" - \(query.primaryArtist)")
        let strippedTitle = query.title.strippedTrackTitle
        let keyword = "\(strippedTitle) \(query.primaryArtist)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = try searchSong(keyword)
        writeDebugLog("[Genius] Search returned \(hits.count) hit(s)")

        guard !hits.isEmpty else {
            throw LyricsError.noSuchSong
        }

        let song = mostRelevantHitResult(hits: hits, strippedTitle: strippedTitle)
        let songInfo = try getSongInfo(song.id)

        let plainLines = songInfo.lyrics.plain.components(separatedBy: .newlines)
        let mappedLines = GeniusLyricsRepository.mapLyricsLines(plainLines)

        // 不把上游「空歌词 → 纯音乐占位」的 bug 带过来：无有效歌词就抛查无此歌。
        guard !mappedLines.isEmpty else {
            writeDebugLog("[Genius] No usable lyrics")
            throw LyricsError.noSuchSong
        }

        var romanization = LyricsRomanizationStatus.original
        if songInfo.language.isCanBeRomanizedLanguage {
            romanization = .canBeRomanized
        }

        writeDebugLog("[Genius] Using \"\(song.title)\" — \(mappedLines.count) line(s)")
        return LyricsDto(
            lines: mappedLines.map { LyricsLineDto(content: $0) },
            timeSynced: false,
            romanization: romanization,
            languageCode: songInfo.language
        )
    }
}
