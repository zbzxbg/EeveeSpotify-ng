import Foundation

class PetitLyricsRepository: LyricsRepository {
    private let url = "https://p1.petitlyrics.com/api/GetPetitLyricsData.php"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        
        session = URLSession(configuration: configuration)
    }
    
    private func perform(_ data: [String: Any]) throws -> PetitResponse {
        var finalData = data

        finalData["clientAppId"] = "p1110417"
        finalData["terminalType"] = 10
        
        var request = URLRequest(url: URL(string: url)!)
        
        request.httpMethod = "POST"
        request.httpBody = finalData.queryString.data(using: .utf8)

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
        
        guard let response = try? XMLDecoder().decode(PetitResponse.self, from: data!) else {
            throw LyricsError.decodingError
        }

        return response
    }
    
    //
    
    private func searchSong(_ title: String, artist: String) throws -> PetitSong {
        let response = try perform(
            ["key_title": title, "key_artist": artist, "max_count": 1]
        )
        
        guard let song = response.songs.first else {
            throw LyricsError.noSuchSong
        }
        
        return song
    }
    
    //
    
    private func getSong(_ lyricsId: Int, availableLyricsType: PetitLyricsType) throws -> PetitSong {
        var lyricsType: PetitLyricsType
        
        if availableLyricsType == .linesSynced {
            lyricsType = .plain
        }
        else {
            lyricsType = availableLyricsType
        }
        
        let response = try perform(
            ["key_lyricsId": lyricsId, "lyricsType": lyricsType.rawValue]
        )
        
        guard let song = response.songs.first else {
            throw LyricsError.noSuchSong
        }
        
        return song
    }
    
    //
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        writeDebugLog("[Petit] Fetching lyrics for \"\(query.title)\" - \(query.primaryArtist)")
        let searchResult = try searchSong(query.title, artist: query.primaryArtist)
        let song = try getSong(
            searchResult.lyricsId,
            availableLyricsType: searchResult.availableLyricsType
        )
        
        guard let lyricsData = Data(base64Encoded: song.lyricsData) else {
            throw LyricsError.decodingError
        }
        
        switch song.lyricsType {
            
        case .wordsSynced:
            guard let lyrics = try? XMLDecoder().decode(PetitLyricsData.self, from: lyricsData) 
            else {
                throw LyricsError.decodingError
            }

            if !Self.didDumpRawXml {
                Self.didDumpRawXml = true
                if let xml = String(data: lyricsData, encoding: .utf8) {
                    writeDebugLog("[Petit] raw XML head: \(xml.prefix(1000))")
                }
            }
            
            // Petit 的 starttime/endtime 单位不稳定（厘秒/毫秒），按词间距中位数判定后统一换算成毫秒。
            let unitMultiplier = Self.timeUnitMultiplier(for: lyrics.lines)

            let preserveWords = NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
            writeDebugLog("[Petit] Words-synced lyrics — \(lyrics.lines.count) line(s)\(preserveWords ? " (word-by-word preserved)" : "")")
            return LyricsDto(
                lines: lyrics.lines.map {
                    LyricsLineDto(
                        content: $0.linestring,
                        offsetMs: ($0.words.first?.starttime).map { $0 * unitMultiplier },
                        words: preserveWords ? Self.wordDto(for: $0, multiplier: unitMultiplier) : nil
                    )
                },
                timeSynced: true,
                romanization: lyrics.lines.map { $0.linestring }.canBeRomanized
                    ? .canBeRomanized
                    : .original
            )
            
        case .plain:
            let stringLyrics = String(data: lyricsData, encoding: .utf8)!
            let lines = stringLyrics.components(separatedBy: "\n")
            writeDebugLog("[Petit] Plain lyrics — \(lines.count) line(s)")
            return LyricsDto(
                lines: lines.map { LyricsLineDto(content: $0) },
                timeSynced: false,
                romanization: lines.canBeRomanized ? .canBeRomanized : .original
            )
            
        default:
            throw LyricsError.decodingError
        }
    }

    private static var didDumpRawXml = false
    private static var didLogDegenerate = false

    /// 检测 Petit 词级时间轴的单位：部分歌是厘秒(1/100s)，部分歌是毫秒。
    /// 依据：词起始时间差的中位数。毫秒解释下中位数 < 50ms（相当于 >20 字/秒，人声不可能），
    /// 说明实为厘秒，需 ×10。
    private static func timeUnitMultiplier(for lines: [PetitLyricsLine]) -> Int {
        var gaps: [Int] = []
        for line in lines {
            let starts = line.words.map { $0.starttime }
            for i in 1..<starts.count {
                let gap = starts[i] - starts[i - 1]
                if gap > 0 { gaps.append(gap) }
            }
        }
        guard !gaps.isEmpty else { return 1 }
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        let isCentiseconds = median < 50
        writeDebugLog("[Petit] time unit: \(isCentiseconds ? "centiseconds (×10)" : "milliseconds (×1)") — median word gap \(median)")
        return isCentiseconds ? 10 : 1
    }

    /// Petit 的 wordsSynced 词元素通常只带 starttime、不带词文本，
    /// 词文本需从 linestring 推导：先按空白切分；日语无空格时按逐字符切分对齐词数。
    private static func wordDto(for line: PetitLyricsLine, multiplier: Int) -> [LyricsWordDto]? {
        let words = line.words
        guard !words.isEmpty else { return nil }

        // 退化检测：所有词 starttime 相同 = 该行无逐字时间轴（Petit 对某些歌返回伪 wordsSynced）
        let firstStart = words[0].starttime
        if words.allSatisfy({ $0.starttime == firstStart }) {
            if !Self.didLogDegenerate {
                Self.didLogDegenerate = true
                writeDebugLog("[Petit] degenerate wordsSynced (all words same starttime \(firstStart)) — fall back to line-level")
            }
            return nil
        }

        // Petit 的 word 元素带 wordstring（词文本，含空格 token）+ starttime + endtime
        if words.allSatisfy({ $0.wordstring != nil }) {
            return words.map {
                LyricsWordDto(
                    text: $0.wordstring ?? "",
                    startMs: $0.starttime * multiplier,
                    endMs: $0.endtime.map { $0 * multiplier }
                )
            }
        }

        // 兜底：wordstring 缺失时按逐字符切分对齐词数
        let chars = line.linestring.filter { !$0.isWhitespace }.map(String.init)
        if chars.count == words.count {
            return zip(chars, words).map { LyricsWordDto(text: $0, startMs: $1.starttime * multiplier) }
        }

        writeDebugLog("[Petit] wordstring unavailable — chars \(chars.count) vs words \(words.count): \"\(line.linestring.prefix(60))\"")
        return nil
    }
}
