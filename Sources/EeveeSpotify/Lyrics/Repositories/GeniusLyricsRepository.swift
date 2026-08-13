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
        
        guard
            case .sections(let sectionsResponse) = data,
            let section = sectionsResponse.sections.first
        else {
            throw LyricsError.decodingError
        }
        
        return section.hits
    }

    private func getSongInfo(_ songId: Int) throws -> GeniusSong {
        let data = try perform("/songs/\(songId)", query: ["text_format": "plain"])
        
        guard case .song(let songResponse) = data else {
            throw LyricsError.decodingError
        }
        
        return songResponse.song
    }
    
    //
    
    private func mostRelevantHitResult(
        hits: [GeniusHit],
        strippedTitle: String,
        romanized: Bool,
        hasFoundRomanizedLyrics: inout Bool
    ) -> GeniusHitResult {
        let results = hits.map { $0.result }
        
        let matchingByTitle = results.filter(
            { $0.title.containsInsensitive(strippedTitle) }
        )
        
        if matchingByTitle.isEmpty {
            return results.first!
        }
        
        if romanized, let romanizedSong = matchingByTitle.first(
            where: { $0.artistNames == "Genius Romanizations" }
        ) {
            hasFoundRomanizedLyrics = true
            return romanizedSong
        }
        
        return matchingByTitle.first!
    }
    
    // MARK: - 歌词行过滤
    
    /// 标准化字符串：忽略大小写和重音符号
    private func normalizedString(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
         .lowercased()
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// 段落标记关键词集合（已标准化）
    private static let sectionKeywords: Set<String> = {
        let keywords = [
            "intro", "introducao", "introdução",
            "verse", "verso",
            "chorus", "refrao", "refrão",
            "pre-chorus", "pre-refrao", "pré-refrão",
            "post-chorus", "pos-refrao", "pós-refrão",
            "bridge", "ponte",
            "hook", "gancho",
            "interlude", "interludio", "interlúdio",
            "solo", "instrumental",
            "outro", "encerramento",
            "drop",
            "break", "breakdown",
            "fade out"
        ]
        return Set(keywords.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased() })
    }()
    
    /// 标题前缀（已标准化）
    private static let titlePrefixes: [String] = {
        let prefixes = [
            "letra de \"",
            "tekisuto o letra de \"",
            "text of \""
        ]
        return prefixes.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased() }
    }()
    
    /// 判断一行是否是段落标记或标题行
    private func isSectionHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        let normalizedLine = normalizedString(trimmed)
        
        // 检查标题前缀，如 LETRA DE "xxx"
        if Self.titlePrefixes.contains(where: { normalizedLine.hasPrefix($0) }) {
            return true
        }
        
        // 检查圆括号包裹的段落标记，如 (INTRO)
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
            let inner = trimmed.dropFirst().dropLast()
            let normalizedInner = normalizedString(String(inner))
            if Self.sectionKeywords.contains(normalizedInner) {
                return true
            }
        }
        
        // 检查无括号的独立段落标记，如 VERSO、REFRAO
        if Self.sectionKeywords.contains(normalizedLine) {
            return true
        }
        
        return false
    }
    
    private func mapLyricsLines(_ rawLines: [String]) -> [String] {
        var lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
        
        // 移除方括号标记（原有逻辑）以及新的段落标记/标题行
        lines.removeAll { line in
            line.range(of: "\\[.*\\]", options: .regularExpression) != nil ||
            isSectionHeader(line)
        }
        
        // 去除开头和结尾的空行
        lines = Array(
            lines
                .drop(while: { $0.isEmpty })
                .dropLast(while: { $0.isEmpty })
        )
        
        return lines
    }
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let strippedTitle = query.title.strippedTrackTitle
        let hits = try searchSong("\(strippedTitle) \(query.primaryArtist)")
    
        guard !hits.isEmpty else {
            throw LyricsError.noSuchSong
        }
        
        var hasFoundRomanizedLyrics = false
        
        let song = mostRelevantHitResult(
            hits: hits,
            strippedTitle: strippedTitle,
            romanized: options.romanization,
            hasFoundRomanizedLyrics: &hasFoundRomanizedLyrics
        )
        
        let songInfo = try getSongInfo(song.id)
        let plainLines = songInfo.lyrics.plain.components(separatedBy: "\n")
        
        var romanization = LyricsRomanizationStatus.original
        
        if hasFoundRomanizedLyrics {
            romanization = .romanized
        }
        else if songInfo.language.isCanBeRomanizedLanguage {
            romanization = .canBeRomanized
        }
    
        return LyricsDto(
            lines: mapLyricsLines(plainLines).map { line in LyricsLineDto(content: line) },
            timeSynced: false,
            romanization: romanization
        )
    }
}