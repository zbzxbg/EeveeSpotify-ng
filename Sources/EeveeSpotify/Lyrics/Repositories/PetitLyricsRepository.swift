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
            
            let preserveWords = NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
            writeDebugLog("[Petit] Words-synced lyrics — \(lyrics.lines.count) line(s)\(preserveWords ? " (word-by-word preserved)" : "")")
            return LyricsDto(
                lines: lyrics.lines.map {
                    LyricsLineDto(
                        content: $0.linestring,
                        offsetMs: $0.words.first?.starttime,
                        words: preserveWords ? Self.wordDto(for: $0) : nil
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

    /// Petit 的 wordsSynced 词元素通常只带 starttime、不带词文本，
    /// 词文本需从 linestring 推导：先按空白切分；日语无空格时按逐字符切分对齐词数。
    private static func wordDto(for line: PetitLyricsLine) -> [LyricsWordDto]? {
        let words = line.words
        guard !words.isEmpty else { return nil }

        // Petit 的 word 元素带 wordstring（词文本，含空格 token）+ starttime + endtime
        if words.allSatisfy({ $0.wordstring != nil }) {
            return words.map {
                LyricsWordDto(text: $0.wordstring ?? "", startMs: $0.starttime, endMs: $0.endtime)
            }
        }

        // 兜底：wordstring 缺失时按逐字符切分对齐词数
        let chars = line.linestring.filter { !$0.isWhitespace }.map(String.init)
        if chars.count == words.count {
            return zip(chars, words).map { LyricsWordDto(text: $0, startMs: $1.starttime) }
        }

        writeDebugLog("[Petit] wordstring unavailable — chars \(chars.count) vs words \(words.count): \"\(line.linestring.prefix(60))\"")
        return nil
    }
}
