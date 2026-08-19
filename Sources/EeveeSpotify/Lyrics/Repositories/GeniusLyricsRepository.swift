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
        semaphore.wait()

        if let error = error {
            throw error
        }

        guard let rootResponse = try? jsonDecoder.decode(GeniusRootResponse.self, from: data!) else {
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

    private func searchSongs(for query: LyricsSearchQuery, strippedTitle: String) throws -> [GeniusHit] {
        let queries = [
            "\(query.title) \(query.primaryArtist)",
            "\(strippedTitle) \(query.primaryArtist)"
        ]

        var searchedQueries = Set<String>()
        var hitsByID = [Int:GeniusHit]()

        for rawSearchQuery in queries {
            let searchQuery = rawSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !searchQuery.isEmpty, searchedQueries.insert(searchQuery).inserted else {
                continue
            }

            do {
                let hits = try searchSong(searchQuery)
                for hit in hits {
                    hitsByID[hit.result.id] = hit
                }
            } catch {
                continue
            }
        }

        if !hitsByID.isEmpty {
            return Array(hitsByID.values)
        }

        // If neither query produced a song, preserve whoeevee's no-song
        // behavior even when one of the alternate searches also failed.
        // Otherwise the final fallback path may treat a search miss as a
        // generic Genius failure and silently return empty lyrics.
        throw LyricsError.noSuchSong
    }

    private func getSongInfo(_ songId: Int) throws -> GeniusSong {
        let data = try perform("/songs/\(songId)", query: ["text_format": "plain"])

        guard case .song(let songResponse) = data else {
            throw LyricsError.decodingError
        }

        return songResponse.song
    }

    //

    private func normalizedSearchText(_ text: String) -> String {
        text
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
            .replacingOccurrences(
                of: "[^\\p{L}\\p{N}]+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isGeniusRomanization(_ result: GeniusHitResult) -> Bool {
        result.artistNames.caseInsensitiveCompare("Genius Romanizations") == .orderedSame
    }

    private func titleMatchScore(
        for result: GeniusHitResult,
        title: String,
        strippedTitle: String,
        primaryArtist: String,
        preferRomanized: Bool
    ) -> Int {
        let resultTitle = normalizedSearchText(result.title)
        let fullTitle = normalizedSearchText(title)
        let cleanTitle = normalizedSearchText(strippedTitle)
        let resultArtist = normalizedSearchText(result.artistNames)
        let queryArtist = normalizedSearchText(primaryArtist)

        var score = 0
        if !fullTitle.isEmpty, resultTitle == fullTitle {
            score += 100
        } else if !cleanTitle.isEmpty, resultTitle == cleanTitle {
            score += 90
        } else if !fullTitle.isEmpty && (resultTitle.contains(fullTitle) || fullTitle.contains(resultTitle)) {
            score += 70
        } else if !cleanTitle.isEmpty && (resultTitle.contains(cleanTitle) || cleanTitle.contains(resultTitle)) {
            score += 55
        }

        if !queryArtist.isEmpty && !isGeniusRomanization(result) {
            if resultArtist == queryArtist {
                score += 60
            } else if resultArtist.contains(queryArtist) || queryArtist.contains(resultArtist) {
                score += 40
            } else {
                let artistTokens = queryArtist.split(separator: " ")
                if artistTokens.contains(where: { resultArtist.contains(String($0)) }) {
                    score += 15
                } else {
                    score -= 80
                }
            }
        }

        if isGeniusRomanization(result) {
            score += preferRomanized ? 100 : -1000
        }

        return score
    }

    private func mostRelevantHitResult(
        hits: [GeniusHit],
        title: String,
        strippedTitle: String,
        primaryArtist: String,
        preferRomanized: Bool
    ) throws -> GeniusHitResult {
        let results = hits.map { $0.result }
        let eligibleResults = preferRomanized
            ? results
            : results.filter { !isGeniusRomanization($0) }

        guard !eligibleResults.isEmpty else {
            throw LyricsError.noSuchSong
        }

        guard let bestResult = eligibleResults.max(by: { lhs, rhs in
            titleMatchScore(
                for: lhs,
                title: title,
                strippedTitle: strippedTitle,
                primaryArtist: primaryArtist,
                preferRomanized: preferRomanized
            ) < titleMatchScore(
                for: rhs,
                title: title,
                strippedTitle: strippedTitle,
                primaryArtist: primaryArtist,
                preferRomanized: preferRomanized
            )
        }) else {
            throw LyricsError.noSuchSong
        }

        let bestScore = titleMatchScore(
            for: bestResult,
            title: title,
            strippedTitle: strippedTitle,
            primaryArtist: primaryArtist,
            preferRomanized: preferRomanized
        )
        guard bestScore >= 40 else {
            throw LyricsError.noSuchSong
        }

        return bestResult
    }

    private func isGeniusRomanizationEnabled(for languageCode: String) -> Bool {
        guard UserDefaults.lyricsOptions.romanization else { return false }

        let normalizedCode = languageCode.lowercased()
        if normalizedCode.hasPrefix("ja") {
            return UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization")
        }
        if normalizedCode.hasPrefix("ko") {
            return UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization")
        }
        if normalizedCode.hasPrefix("zh") || normalizedCode == "z1" {
            return UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization")
        }
        return false
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
    private func normalizedForMarkerMatch(_ line: String) -> String {
        return line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: nil)
            .uppercased()
    }

    /// True if the line is structural metadata rather than actual lyric content:
    /// recognized bracketed tags, parenthesized section markers, bare section-marker
    /// lines, or `Letra de "..."` / `Text of "..."` style headers.
    private func isNonLyricLine(_ line: String) -> Bool {
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

    private func mapLyricsLines(_ rawLines: [String]) -> [String] {
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
        let strippedTitle = query.title.strippedTrackTitle
        let hits = try searchSongs(for: query, strippedTitle: strippedTitle)

        var song = try mostRelevantHitResult(
            hits: hits,
            title: query.title,
            strippedTitle: strippedTitle,
            primaryArtist: query.primaryArtist,
            preferRomanized: options.romanization
        )
        var songInfo = try getSongInfo(song.id)

        // A Genius Romanizations result is only valid when the global switch and
        // the corresponding ngzhwm language switch are both enabled. If not,
        // select the best non-romanized result instead.
        if isGeniusRomanization(song), !isGeniusRomanizationEnabled(for: songInfo.language) {
            let originalHits = hits.filter { !isGeniusRomanization($0.result) }
            guard !originalHits.isEmpty else {
                throw LyricsError.noSuchSong
            }

            song = try mostRelevantHitResult(
                hits: originalHits,
                title: query.title,
                strippedTitle: strippedTitle,
                primaryArtist: query.primaryArtist,
                preferRomanized: false
            )
            songInfo = try getSongInfo(song.id)
        }

        let plainLines = songInfo.lyrics.plain.components(separatedBy: .newlines)
        let mappedLines = mapLyricsLines(plainLines)

        // Treat a song page without valid lyric lines as unavailable lyrics.
        // This keeps Genius errors consistent whether the song is not found
        // in search or its page contains no usable lyric content.
        guard !mappedLines.isEmpty else {
            throw LyricsError.noSuchSong
        }

        var romanization = LyricsRomanizationStatus.original

        if isGeniusRomanization(song) {
            romanization = .romanized
        }
        else if songInfo.language.isCanBeRomanizedLanguage {
            romanization = .canBeRomanized
        }

        return LyricsDto(
            lines: mappedLines.map { LyricsLineDto(content: $0) },
            timeSynced: false,
            romanization: romanization,
            languageCode: songInfo.language
        )
    }
}
