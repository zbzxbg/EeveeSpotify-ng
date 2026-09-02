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
            
            // Petit 的 starttime/endtime 单位不稳定：行起始时间永远是毫秒（首词 starttime 即绝对 ms），
            // 但词时间在「厘秒格式」下是「相对行首的厘秒差」（存的整数值 = 行首 + 厘秒差，未 ×10）。
            let centi = Self.isCentiseconds(lyrics.lines)

            // 诊断：首末行时间跨度（行起始 = 毫秒，不乘任何系数）
            if let firstLine = lyrics.lines.first?.words.first?.starttime,
                let lastLine = lyrics.lines.last?.words.first?.starttime
            {
                writeDebugLog("[Petit] line span: first=\(firstLine)ms last=\(lastLine)ms (\(lyrics.lines.count) lines)")
            }

            // 卡拉OK音源导入段校正：WSY 时间轴起点是「卡拉OK音源」的起点，
            // 部分歌开头有一段导入（静音/计数），首行会用「空 linestring + 单零时长词」作标记，
            // 其 starttime 即音乐真正开始的时点（Spotify 音频 t=0 对应这里）。
            // 不从时间轴里减掉它，整首歌词会整体晚 leadIn 毫秒（如「ふり」晚 6999ms ≈ 7s）。
            let leadInMs = Self.leadInOffsetMs(lyrics.lines)
            if leadInMs > 0 {
                writeDebugLog("[Petit] karaoke lead-in \(leadInMs)ms — shifting timeline")
            }

            let sourceLines = leadInMs > 0 ? Array(lyrics.lines.dropFirst()) : lyrics.lines
            let preserveWords = NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
            writeDebugLog("[Petit] Words-synced lyrics — \(sourceLines.count) line(s)\(preserveWords ? " (word-by-word preserved)" : "")")
            return LyricsDto(
                lines: sourceLines.map {
                    LyricsLineDto(
                        content: $0.linestring,
                        offsetMs: $0.words.first.map { $0.starttime - leadInMs },
                        words: preserveWords ? Self.wordDto(for: $0, isCentiseconds: centi, leadInMs: leadInMs) : nil
                    )
                },
                timeSynced: true,
                romanization: sourceLines.map { $0.linestring }.canBeRomanized
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
    /// 说明实为厘秒。
    private static func isCentiseconds(_ lines: [PetitLyricsLine]) -> Bool {
        var gaps: [Int] = []
        for line in lines {
            let starts = line.words.map { $0.starttime }
            for i in 1..<starts.count {
                let gap = starts[i] - starts[i - 1]
                if gap > 0 { gaps.append(gap) }
            }
        }
        guard !gaps.isEmpty else { return false }
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        let centi = median < 50
        writeDebugLog("[Petit] time unit: \(centi ? "centiseconds" : "milliseconds") — median word gap \(median)")
        return centi
    }

    /// 检测卡拉OK音源导入段并返回其毫秒偏移。
    /// 导入段签名：首行 linestring 为空 + 恰好一个词 + 词文本为空 + 词时长为零（starttime==endtime）。
    /// 这种行是 Petit WSY 的「音乐开始点」标记，不是歌词；返回其 starttime 作为要在所有时间轴上减去的偏移。
    /// 无此标记（首行即真歌词）时返回 0，不改变时间轴。
    private static func leadInOffsetMs(_ lines: [PetitLyricsLine]) -> Int {
        guard let first = lines.first,
              first.linestring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              first.words.count == 1,
              let marker = first.words.first,
              marker.wordstring?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
              marker.starttime == (marker.endtime ?? marker.starttime) else {
            return 0
        }
        return marker.starttime
    }

    /// Petit 的 wordsSynced 词元素通常只带 starttime、不带词文本，
    /// 词文本需从 linestring 推导：先按空白切分；日语无空格时按逐字符切分对齐词数。
    private static func wordDto(for line: PetitLyricsLine, isCentiseconds: Bool, leadInMs: Int) -> [LyricsWordDto]? {
        let words = line.words
        guard !words.isEmpty else { return nil }

        // 行起始 = 首词 starttime（毫秒，绝对时间）
        let lineOffsetMs = words[0].starttime

        // 退化检测：多词行里所有词 starttime 相同 = 该行无逐字时间轴（Petit 对某些歌返回伪 wordsSynced）。
        // 单词行（words.count == 1）不能判退化：allSatisfy 对单元素数组恒为真，会误丢单词行的时间轴。
        if words.count > 1 && words.allSatisfy({ $0.starttime == lineOffsetMs }) {
            if !Self.didLogDegenerate {
                Self.didLogDegenerate = true
                writeDebugLog("[Petit] degenerate wordsSynced (all words same starttime \(lineOffsetMs)) — fall back to line-level")
            }
            return nil
        }

        // 厘秒格式：词时间是「相对行首的厘秒差」（整数值 = 行首 + 厘秒差，未 ×10），换算成绝对毫秒；
        // 毫秒格式：词时间本身就是绝对毫秒。
        func convert(_ raw: Int) -> Int {
            (isCentiseconds ? lineOffsetMs + (raw - lineOffsetMs) * 10 : raw) - leadInMs
        }

        // Petit 的 word 元素带 wordstring（词文本，含空格 token）+ starttime + endtime
        if words.allSatisfy({ $0.wordstring != nil }) {
            return words.map {
                let raw = $0.wordstring ?? ""
                // 空格 token 的 wordstring 是纯空白（可能被解码器 trim 成空串），恢复为空格，
                // 否则英文词与词会挤在一起
                let text = raw.isEmpty ? " " : raw
                return LyricsWordDto(
                    text: text,
                    startMs: convert($0.starttime),
                    endMs: $0.endtime.map { convert($0) }
                )
            }
        }

        // 兜底：wordstring 缺失时按切分对齐词数——
        // 日文（无空格）按逐字符切，英文按空白切，避免英文被拆成单个字母
        let tokens: [String]
        if Self.containsCJK(line.linestring) {
            tokens = line.linestring.filter { !$0.isWhitespace }.map(String.init)
        } else {
            tokens = line.linestring.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        if tokens.count == words.count {
            return zip(tokens, words).map { LyricsWordDto(text: $0, startMs: convert($1.starttime)) }
        }

        writeDebugLog("[Petit] wordstring unavailable — tokens \(tokens.count) vs words \(words.count): \"\(line.linestring.prefix(60))\"")
        return nil
    }

    /// 是否含 CJK 字符（假名/汉字/韩文）。
    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF,   // 平/片假名
                 0x3400...0x4DBF,   // CJK 扩展 A
                 0x4E00...0x9FFF,   // CJK 统一汉字
                 0xAC00...0xD7AF,   // 韩文谚文
                 0xF900...0xFAFF,   // CJK 兼容
                 0xFF66...0xFF9D:   // 半角片假名
                return true
            default:
                return false
            }
        }
    }
}
