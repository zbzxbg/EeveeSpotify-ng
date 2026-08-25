import Foundation

class GeniusLyricsRepository: LyricsRepository {
    /// Upper bound on how many candidate song pages we fetch before giving up.
    /// Generous enough to find the right page even when heuristics fail
    /// (e.g. different scripts), while avoiding unbounded requests.
    private let maxCandidateFetches = 20

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

    private func searchSongs(for query: LyricsSearchQuery, strippedTitle: String) throws -> [GeniusHit] {
        let queries = [
            "\(query.title) \(query.primaryArtist)",
            "\(strippedTitle) \(query.primaryArtist)",
            query.title,
            strippedTitle
        ]

        var searchedQueries = Set<String>()
        var hits: [GeniusHit] = []
        var seenIDs = Set<Int>()
        var lastSearchError: Error?

        for rawSearchQuery in queries {
            let searchQuery = rawSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !searchQuery.isEmpty, searchedQueries.insert(searchQuery).inserted else {
                continue
            }

            do {
                let newHits = try searchSong(searchQuery)
                for hit in newHits {
                    // Keep first-seen (most relevant) order and dedupe by song id.
                    if seenIDs.insert(hit.result.id).inserted {
                        hits.append(hit)
                    }
                }
            } catch {
                lastSearchError = error
                continue
            }
        }

        if !hits.isEmpty {
            return hits
        }

        // A transient failure must not masquerade as "no such song": surfacing
        // the real error avoids showing "no lyrics" when we simply couldn't
        // reach Genius this time.
        if let lastSearchError = lastSearchError {
            throw lastSearchError
        }

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

    /// Returns true when the requested artist appears as a complete token sequence
    /// in the Genius result artist name. This allows collaboration results such as
    /// "Artist & Another Artist" without treating a short name like "m" as a match
    /// for an unrelated artist such as "Maroon 5".
    private func containsWholeArtistPhrase(_ phrase: String, in text: String) -> Bool {
        let phraseTokens = phrase.split(separator: " ")
        let textTokens = text.split(separator: " ")

        guard !phraseTokens.isEmpty, phraseTokens.count <= textTokens.count else {
            return false
        }

        for startIndex in 0...(textTokens.count - phraseTokens.count) {
            let endIndex = startIndex + phraseTokens.count
            if Array(textTokens[startIndex..<endIndex]) == phraseTokens {
                return true
            }
        }

        return false
    }

    private func artistMatches(
        result: GeniusHitResult,
        primaryArtist: String
    ) -> Bool {
        guard !isGeniusRomanization(result) else { return true }

        let queryArtist = normalizedSearchText(primaryArtist)
        guard !queryArtist.isEmpty else { return true }

        let resultArtist = normalizedSearchText(result.artistNames)
        guard !resultArtist.isEmpty else { return false }

        return resultArtist == queryArtist
            || containsWholeArtistPhrase(queryArtist, in: resultArtist)
    }

    private func titleMatches(
        resultTitle: String,
        title: String,
        strippedTitle: String
    ) -> Bool {
        let normalizedResultTitle = normalizedSearchText(resultTitle)
        let fullTitle = normalizedSearchText(title)
        let cleanTitle = normalizedSearchText(strippedTitle)

        guard !normalizedResultTitle.isEmpty else { return false }

        return (!fullTitle.isEmpty && normalizedResultTitle == fullTitle)
            || (!cleanTitle.isEmpty && normalizedResultTitle == cleanTitle)
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
        } else if (!fullTitle.isEmpty && (resultTitle.contains(fullTitle) || fullTitle.contains(resultTitle)))
            || (!cleanTitle.isEmpty && (resultTitle.contains(cleanTitle) || cleanTitle.contains(resultTitle))) {
            // 子串匹配（参考上游 containsInsensitive）：覆盖 "Song (Original Mix)"
            // 这类版本/格式变体，避免直接掉进野生兜底返回错误歌词。
            score += 70
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

    /// Ranks search hits so the best title/artist match is tried first, while
    /// still keeping every hit as a fallback candidate. Equal scores keep the
    /// original search order (most relevant query first), which matters when
    /// Spotify metadata and Genius titles/artists use different scripts and the
    /// heuristic score is uninformative.
    private func rankedHitResults(
        hits: [GeniusHit],
        title: String,
        strippedTitle: String,
        primaryArtist: String,
        preferRomanized: Bool
    ) -> [GeniusHitResult] {
        return hits
            .enumerated()
            .map { (index: $0.offset, result: $0.element.result) }
            .sorted { lhs, rhs in
                let lhsScore = titleMatchScore(
                    for: lhs.result,
                    title: title,
                    strippedTitle: strippedTitle,
                    primaryArtist: primaryArtist,
                    preferRomanized: preferRomanized
                )
                let rhsScore = titleMatchScore(
                    for: rhs.result,
                    title: title,
                    strippedTitle: strippedTitle,
                    primaryArtist: primaryArtist,
                    preferRomanized: preferRomanized
                )
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return lhs.index < rhs.index
            }
            .map { $0.result }
    }

    /// Strict-match candidate selection (ngzhwm_geniusStrictMatch ON): only
    /// results whose title AND artist match the requested song AND whose match
    /// score is at least 40 are kept. Preferring to return "no lyrics" over a
    /// wrong song — a candidate is never accepted on a loose match.
    private func strictEligibleHitResults(
        hits: [GeniusHit],
        title: String,
        strippedTitle: String,
        primaryArtist: String,
        preferRomanized: Bool
    ) -> [GeniusHitResult] {
        return hits
            .enumerated()
            .map { (index: $0.offset, result: $0.element.result) }
            .filter { pair in
                let result = pair.result

                guard preferRomanized || !isGeniusRomanization(result) else {
                    return false
                }

                let titleIsCompatible = isGeniusRomanization(result)
                    || titleMatches(
                        resultTitle: result.title,
                        title: title,
                        strippedTitle: strippedTitle
                    )
                guard titleIsCompatible,
                      artistMatches(result: result, primaryArtist: primaryArtist) else {
                    return false
                }

                return titleMatchScore(
                    for: result,
                    title: title,
                    strippedTitle: strippedTitle,
                    primaryArtist: primaryArtist,
                    preferRomanized: preferRomanized
                ) >= 40
            }
            .sorted { lhs, rhs in
                let lhsScore = titleMatchScore(
                    for: lhs.result,
                    title: title,
                    strippedTitle: strippedTitle,
                    primaryArtist: primaryArtist,
                    preferRomanized: preferRomanized
                )
                let rhsScore = titleMatchScore(
                    for: rhs.result,
                    title: title,
                    strippedTitle: strippedTitle,
                    primaryArtist: primaryArtist,
                    preferRomanized: preferRomanized
                )
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return lhs.index < rhs.index
            }
            .map { $0.result }
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
        let hits = try searchSongs(for: query, strippedTitle: strippedTitle)
        writeDebugLog("[Genius] Search returned \(hits.count) hit(s)")

        let strictMatch = UserDefaults.standard.bool(forKey: NgzhwmSettingsViewModel.geniusStrictMatchKey)

        // strictMatch ON  -> precision-first: only a confident (title + artist
        //   matched, scored >= 40) candidate may be returned. Never show a wrong
        //   song; reporting "no lyrics" is acceptable.
        // strictMatch OFF -> recall-first: allow a slightly wrong version rather
        //   than miss lyrics entirely.
        let candidates: [GeniusHitResult]
        if strictMatch {
            let eligible = strictEligibleHitResults(
                hits: hits,
                title: query.title,
                strippedTitle: strippedTitle,
                primaryArtist: query.primaryArtist,
                preferRomanized: options.romanization
            )
            guard !eligible.isEmpty else {
                writeDebugLog("[Genius] Strict match found no eligible candidate")
                throw LyricsError.noSuchSong
            }
            candidates = eligible
        } else {
            candidates = rankedHitResults(
                hits: hits,
                title: query.title,
                strippedTitle: strippedTitle,
                primaryArtist: query.primaryArtist,
                preferRomanized: options.romanization
            )
        }

        // Walk candidates from best to worst match and return the first page
        // that actually contains usable lyric lines. This favors recall over
        // precision: a slightly wrong version is better than reporting "no
        // lyrics" while a valid page exists among the search results.
        for candidate in candidates.prefix(maxCandidateFetches) {
            let songInfo: GeniusSong
            do {
                songInfo = try getSongInfo(candidate.id)
            } catch {
                continue
            }

            // A Genius Romanizations result is only valid when the global switch
            // and the corresponding ngzhwm language switch are both enabled.
            // Otherwise fall through to the next (non-romanized) candidate.
            if isGeniusRomanization(candidate), !isGeniusRomanizationEnabled(for: songInfo.language) {
                continue
            }

            let plainLines = songInfo.lyrics.plain.components(separatedBy: .newlines)
            let mappedLines = GeniusLyricsRepository.mapLyricsLines(plainLines)

            // Skip pages without usable lyric content (instrumentals, tracklists,
            // annotation-only pages) and try the next candidate.
            guard !mappedLines.isEmpty else {
                continue
            }

            var romanization = LyricsRomanizationStatus.original
            if isGeniusRomanization(candidate) {
                romanization = .romanized
            } else if songInfo.language.isCanBeRomanizedLanguage {
                romanization = .canBeRomanized
            }

            writeDebugLog("[Genius] Using candidate \"\(candidate.title)\" — \(mappedLines.count) line(s)")
            return LyricsDto(
                lines: mappedLines.map { LyricsLineDto(content: $0) },
                timeSynced: false,
                romanization: romanization,
                languageCode: songInfo.language
            )
        }

        writeDebugLog("[Genius] No usable lyrics among \(candidates.count) candidate(s)")
        throw LyricsError.noSuchSong
    }
}
