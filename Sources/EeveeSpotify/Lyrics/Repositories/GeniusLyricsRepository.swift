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
    
    private func mapLyricsLines(_ rawLines: [String]) -> [String] {
        var lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
        
        // 删除方括号标签，如 [Verse]
        lines.removeAll { $0 ~= "\\[.*\\]" }
        
        // 删除圆括号或无括号的段标签（如 (INTRO)、VERSO、REFRÃO）
        lines.removeAll { Self.isSectionLabelLine($0) }
        
        // 删除开头和结尾的空行
        lines = Array(
            lines
                .drop(while: { $0.isEmpty })
                .dropLast(while: { $0.isEmpty })
        )
        
        return lines
    }
    
    // MARK: - 段标签清理
    
    private static let sectionTagRegex: NSRegularExpression = {
        // 所有需要被整行移除的段标签（忽略大小写，兼容有无重音）
        let tags = [
            "INTRO", "INTRODUÇÃO", "INTRODUCAO",
            "VERSE", "VERSO",
            "CHORUS", "REFRÃO", "REFRAO",
            "PRE-CHORUS", "PRÉ-REFRÃO", "PRE-REFRÃO", "PRÉ-REFRÃO",
            "POST-CHORUS", "PÓS-REFRÃO", "POS-REFRÃO",
            "BRIDGE", "PONTE",
            "HOOK", "GANCHO",
            "INTERLUDE", "INTERLÚDIO", "INTERLUDIO",
            "SOLO", "INSTRUMENTAL",
            "OUTRO", "ENCERRAMENTO",
            "DROP",
            "BREAK", "BREAKDOWN",
            "FADE OUT",
            "PRE-SAIDA", "SAIDA"
        ]
        
        let escapedTags = tags.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // 匹配一行中一个或多个标签，每个标签可选地被半角或全角圆括号包围，括号前后可有空格
        let pattern = #"^\s*(?:[\(（]?\s*(?:\#(escapedTags))\s*[\)）]?\s*)*$"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()
    
    private static func isSectionLabelLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return sectionTagRegex.firstMatch(in: trimmed, options: [], range: range) != nil
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