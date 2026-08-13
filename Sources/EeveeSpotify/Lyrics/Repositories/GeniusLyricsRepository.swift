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
    
    // MARK: - 歌词行清洗辅助方法
    
    /// 将文本标准化为纯字母形式（小写、去重音、去数字、去空格和符号）
    private func normalizedLabel(_ text: String) -> String {
        let lowercased = text.lowercased()
        let decomposed = lowercased.folding(options: .diacriticInsensitive, locale: .current)
        return decomposed.filter { $0.isLetter }
    }
    
    /// 所有需要去除的音乐段落标注词（标准化后只含字母）
    private let musicSectionLabels: Set<String> = [
        "intro", "introducao", "verse", "verso", "chorus", "refrao",
        "prechorus", "prerefrao", "postchorus", "postrefrao", "posrefrao",
        "bridge", "ponte", "hook", "gancho", "interlude", "interludio",
        "solo", "instrumental", "outro", "encerramento", "drop", "break",
        "breakdown", "fadeout", "presaida", "saida", "loop", "preoutro"
    ]
    
    /// 判断一行是否为需要删除的歌词标题前缀（如 "LETRA DE \""、"Text of \"" 等）
    private func isLanguagePrefixLine(_ line: String) -> Bool {
        let patterns = [
            "^letra de\\s+\"",
            "^tekisuto o letra de\\s+\"",
            "^text of\\s+\""
        ]
        for pattern in patterns {
            if let _ = line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return true
            }
        }
        return false
    }
    
    /// 判断一行是否为音乐段落标注（可能带方括号、圆括号，或无括号独立成行）
    private func isMusicSectionLabel(_ line: String) -> Bool {
        // 提取所有圆括号和方括号内的内容
        var bracketContents: [String] = []
        
        // 匹配圆括号
        let roundRegex = "\\((.*?)\\)"
        if let regex = try? NSRegularExpression(pattern: roundRegex, options: []) {
            let nsLine = line as NSString
            let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length))
            for match in matches {
                if match.numberOfRanges > 0, let range = Range(match.range(at: 1), in: line) {
                    bracketContents.append(String(line[range]))
                }
            }
        }
        
        // 匹配方括号
        let squareRegex = "\\[(.*?)\\]"
        if let regex = try? NSRegularExpression(pattern: squareRegex, options: []) {
            let nsLine = line as NSString
            let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length))
            for match in matches {
                if match.numberOfRanges > 0, let range = Range(match.range(at: 1), in: line) {
                    bracketContents.append(String(line[range]))
                }
            }
        }
        
        // 如果没有括号，直接检查整行标准化后是否为标注词
        if bracketContents.isEmpty {
            return musicSectionLabels.contains(normalizedLabel(line))
        }
        
        // 移除所有括号及内容，检查剩余部分是否只含空白或标点
        var remaining = line
        let combinedPattern = "\\(.*?\\)|\\[.*?\\]"
        if let regex = try? NSRegularExpression(pattern: combinedPattern, options: []) {
            remaining = regex.stringByReplacingMatches(
                in: remaining,
                options: [],
                range: NSRange(location: 0, length: (remaining as NSString).length),
                withTemplate: ""
            )
        }
        
        let trimmedRemaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剩余部分如果没有字母数字，说明括号外无有效歌词
        let hasAlphanumeric = trimmedRemaining.rangeOfCharacter(from: .alphanumerics) != nil
        if hasAlphanumeric {
            return false
        }
        
        // 检查所有括号内容是否都是标注词
        for content in bracketContents {
            if !musicSectionLabels.contains(normalizedLabel(content)) {
                return false
            }
        }
        return true
    }
    
    private func mapLyricsLines(_ rawLines: [String]) -> [String] {
        var lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        
        lines.removeAll { line in
            isLanguagePrefixLine(line) || isMusicSectionLabel(line)
        }
        
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