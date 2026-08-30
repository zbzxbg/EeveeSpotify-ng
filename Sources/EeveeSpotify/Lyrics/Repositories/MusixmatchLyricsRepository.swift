import Foundation
import UIKit

class MusixmatchLyricsRepository: LyricsRepository {
    private let apiUrl = "https://apic.musixmatch.com"

    private var shouldRemoveMxmInterludeSymbol: Bool {
        UserDefaults.standard.bool(forKey: NgzhwmSettingsViewModel.removeMxmInterludeSymbolKey)
    }

    private func cleanedMxmLyricsText(_ text: String) -> String {
        guard shouldRemoveMxmInterludeSymbol, text.contains("♪") else {
            return text
        }

        return ""
    }

    private func isNgzhwmRomanizationEnabled(for romanizationLanguage: String) -> Bool {
        switch romanizationLanguage.lowercased() {
        case "rc", "rz":
            return UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization")
        case "rj":
            return UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization")
        case "rk":
            return UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization")
        default:
            return false
        }
    }

    private var selectedLanguageForRequest: String {
        let normalizedLanguage = selectedLanguage.lowercased()
        guard normalizedLanguage.hasPrefix("r") else {
            return selectedLanguage
        }

        return isNgzhwmRomanizationEnabled(for: selectedLanguage) ? selectedLanguage : ""
    }

    var selectedLanguage: String

    static let shared = MusixmatchLyricsRepository(
        language: UserDefaults.lyricsOptions.musixmatchLanguage
    )

    private init(language: String) {
        selectedLanguage = language
    }

    //

    private class CachedLyrics {
        let dto: LyricsDto

        init(dto: LyricsDto) {
            self.dto = dto
        }
    }

    private let lyricsCache = NSCache<NSString, CachedLyrics>()

    private func getCacheKey(for query: LyricsSearchQuery) -> String {
        let romanizationSettings = [
            UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization"),
            UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization"),
            UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization"),
            shouldRemoveMxmInterludeSymbol,
        ].map { $0 ? "1" : "0" }.joined()

        return "\(query.hashValue)_\(selectedLanguage)_\(romanizationSettings)"
    }

    //

    private func perform(
        _ path: String,
        query: [String: Any] = [:]
    ) throws -> Data {
        var stringUrl = "\(apiUrl)\(path)"
        var finalQuery = query

        finalQuery["usertoken"] = UserDefaults.musixmatchToken
        finalQuery["app_id"] = UIDevice.current.musixmatchAppId

        let queryString = finalQuery.queryString
        stringUrl += "?\(queryString)"

        let request = URLRequest(url: URL(string: stringUrl)!)

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?

        let task = URLSession.shared.dataTask(with: request) { response, _, err in
            error = err
            data = response
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        if let error = error {
            throw error
        }

        return data!
    }

    //

    private func getMacroCalls(_ data: Data) throws -> [String: Any] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let macroCalls = body["macro_calls"] as? [String: Any]
        else {
            throw LyricsError.decodingError
        }

        if let header = message["header"] as? [String: Any],
            header["status_code"] as? Int == 401
        {
            writeDebugLog("[Musixmatch] 401 — invalid token")
            throw LyricsError.invalidMusixmatchToken
        }

        return macroCalls
    }

    private func getFirstSubtitle(_ subtitlesMessage: [String: Any]) throws -> [String: Any] {
        guard
            let subtitlesBody = subtitlesMessage["body"] as? [String: Any],
            let subtitleList = subtitlesBody["subtitle_list"] as? [[String: Any]],
            let firstSubtitle = subtitleList.first,
            let subtitle = firstSubtitle["subtitle"] as? [String: Any]
        else {
            throw LyricsError.decodingError
        }

        if let restricted = subtitle["restricted"] as? Bool, restricted {
            writeDebugLog("[Musixmatch] Lyrics restricted")
            throw LyricsError.musixmatchRestricted
        }

        return subtitle
    }

    //

    private func getTranslations(_ spotifyTrackId: String, selectedLanguage: String) throws
        -> [String: String]
    {
        let data = try perform(
            "/ws/1.1/crowd.track.translations.get",
            query: [
                "track_spotify_id": spotifyTrackId,
                "selected_language": selectedLanguage,
            ]
        )

        guard
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let translationsList = body["translations_list"] as? [[String: Any]]
        else {
            throw LyricsError.decodingError
        }

        let translations = translationsList.compactMap {
            $0["translation"] as? [String: Any]
        }

        return translations.reduce(into: [:]) { dictionary, translation in
            dictionary[translation["subtitle_matched_line"] as! String] =
                translation["description"] as? String
        }
    }

    private func intValue(_ dict: [String: Any], _ key: String) -> Int? {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? Int64 { return Int(value) }
        if let value = dict[key] as? NSNumber { return value.intValue }
        return nil
    }

    /// 用 matcher.track.get 把 Spotify track id / 歌名+歌手解析成 MxM 内部 commontrack id。
    /// 返回 (trackId, hasRichSync)。macro.subtitles.get 的响应里没有 commontrack id，
    /// 必须单独走这一步才能拿到。
    private func getTrackId(_ query: LyricsSearchQuery) throws -> (trackId: Int, hasRichSync: Bool) {
        let data = try perform(
            "/ws/1.1/matcher.track.get",
            query: [
                "track_spotify_id": query.spotifyTrackId,
                "q_track": query.title,
                "q_artist": query.primaryArtist,
            ]
        )

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let track = body["track"] as? [String: Any],
            let trackId = intValue(track, "track_id")
        else {
            throw LyricsError.decodingError
        }

        let hasRichSync = (intValue(track, "has_richsync") ?? 0) == 1
        return (trackId, hasRichSync)
    }

    private func getRichSync(trackId: Int) throws -> [MusixmatchRichSyncLine] {
        let data = try perform(
            "/ws/1.1/track.richsync.get",
            query: ["track_id": trackId]
        )

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let body = message["body"] as? [String: Any],
            let richsync = body["richsync"] as? [String: Any]
        else {
            throw LyricsError.decodingError
        }

        if (intValue(richsync, "restricted") ?? 0) != 0 {
            writeDebugLog("[Musixmatch] richsync restricted")
            throw LyricsError.musixmatchRestricted
        }

        guard
            let richsyncBody = richsync["richsync_body"] as? String,
            let bodyData = richsyncBody.data(using: .utf8)
        else {
            throw LyricsError.decodingError
        }

        writeDebugLog("[Musixmatch] richsync body head: \(richsyncBody.prefix(300))")

        guard let lines = try? JSONDecoder().decode(
            [MusixmatchRichSyncLine].self,
            from: bodyData
        ) else {
            throw LyricsError.decodingError
        }

        return lines
    }

    /// 按行起始时间（±10ms 容差）在 richsync 词表里查找对应的词数组。
    private func wordsAtTime(_ ms: Int, in wordsByTime: [Int: [LyricsWordDto]]) -> [LyricsWordDto]? {
        if let words = wordsByTime[ms] { return words }
        for delta in 1...10 {
            if let words = wordsByTime[ms + delta] { return words }
            if let words = wordsByTime[ms - delta] { return words }
        }
        return nil
    }

    //

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        writeDebugLog("[Musixmatch] Fetching lyrics for \"\(query.title)\" - \(query.primaryArtist)")
        let cacheKey = getCacheKey(for: query)

        if let cached = lyricsCache.object(forKey: cacheKey as NSString) {
            writeDebugLog("[Musixmatch] Cache hit")
            return cached.dto
        }

        var musixmatchQuery = [
            "track_spotify_id": query.spotifyTrackId,
            "subtitle_format": "mxm",
            "q_track": query.title,
            "q_artist": query.primaryArtist,
        ]

        let requestedLanguage = selectedLanguageForRequest

        if !requestedLanguage.isEmpty {
            musixmatchQuery["selected_language"] = requestedLanguage
            musixmatchQuery["part"] = "subtitle_translated"
        }

        let data = try perform(
            "/ws/1.1/macro.subtitles.get",
            query: musixmatchQuery
        )

        var romanized = false
        var translation: LyricsTranslationDto? = nil

        let macroCalls = try getMacroCalls(data)

        // 诊断：宏响应里有哪些子调用，以及是否内嵌了 matcher.track.get（同源 track_id）
        writeDebugLog("[Musixmatch] macro_calls keys: \(macroCalls.keys.sorted().joined(separator: ","))")
        if let matcherCall = macroCalls["matcher.track.get"] as? [String: Any],
            let matcherMessage = matcherCall["message"] as? [String: Any],
            let matcherBody = matcherMessage["body"] as? [String: Any],
            let track = matcherBody["track"] as? [String: Any]
        {
            writeDebugLog("[Musixmatch] macro matcher.track.get — track_id=\(intValue(track, "track_id") ?? -1), has_richsync=\(intValue(track, "has_richsync") ?? 0)")
        }

        if let trackSubtitlesGet = macroCalls["track.subtitles.get"] as? [String: Any],
            let subtitlesMessage = trackSubtitlesGet["message"] as? [String: Any],
            let subtitle = try? getFirstSubtitle(subtitlesMessage),
            let subtitleLanguage = subtitle["subtitle_language"] as? String,
            let subtitleBody = subtitle["subtitle_body"] as? String,
            let subtitles = try? JSONDecoder().decode(
                [MusixmatchSubtitle].self, from: subtitleBody.data(using: .utf8)!
            )
        {

            let romanizationLanguage = "r\(subtitleLanguage.prefix(1))"

            // 逐字歌词：开关开启时先 matcher 解析 commontrack id，再取 richsync 词级时间轴。
            // 行仍用 subtitle（行级，时间可靠），richsync 词按「行起始时间」对齐贴回：
            // 既避免行数不一致按序号错位；个别歌 richsync 时间轴整体偏移（如 Die For You）
            // 时词贴不上，自然回退行级，不会把整首歌时间带歪。
            var richSyncWordsByTimeMs: [Int: [LyricsWordDto]] = [:]
            if NgzhwmSettingsViewModel.isWordByWordLyricsEnabled {
                if let (trackId, hasRichSync) = try? getTrackId(query) {
                    if hasRichSync {
                        if let richSync = try? getRichSync(trackId: trackId) {
                            for richLine in richSync {
                                richSyncWordsByTimeMs[Int(richLine.ts * 1000)] = richLine.l.map {
                                    LyricsWordDto(
                                        text: $0.c,
                                        startMs: Int((richLine.ts + $0.o) * 1000)
                                    )
                                }
                            }
                            let richFirst = richSync.prefix(5).map { String(format: "%.2f", $0.ts) }.joined(separator: ",")
                            let subFirst = subtitles.prefix(5).map { String(format: "%.2f", Double($0.time.total)) }.joined(separator: ",")
                            writeDebugLog("[Musixmatch] Word-by-word (richsync) — \(richSync.count) line(s); richsync ts(first5)=[\(richFirst)] subtitle(first5)=[\(subFirst)]")
                        } else {
                            writeDebugLog("[Musixmatch] richsync unavailable — falling back to line-synced lyrics")
                        }
                    } else {
                        writeDebugLog("[Musixmatch] no richsync (has_richsync=0) — falling back to line-synced lyrics")
                    }
                } else {
                    writeDebugLog("[Musixmatch] matcher.track.get failed — falling back to line-synced lyrics")
                }
            }

            var lyricsLines = subtitles.dropLast().map { subtitle in
                let offsetMs = Int(subtitle.time.total * 1000)
                return LyricsLineDto(
                    content: subtitle.text.lyricsNoteIfEmpty,
                    offsetMs: offsetMs,
                    words: wordsAtTime(offsetMs, in: richSyncWordsByTimeMs)
                )
            }

            lyricsLines.append(
                LyricsLineDto(
                    content: "",
                    offsetMs: Int(subtitles.last!.time.total * 1000)
                )
            )

            // 对齐校验：richsync 词只贴到极少行（如 Die For You 只 1/60），
            // 说明 richsync 与 subtitle 时间轴整体偏移（matcher 解析到错误版本等），
            // 词级数据不可用 —— 全部丢弃，回退纯行级，让 Spotify 原生歌词框架接管。
            let matchedWordLines = lyricsLines.filter { $0.words?.isEmpty == false }.count
            if matchedWordLines * 10 < lyricsLines.count * 3 {
                writeDebugLog("[Musixmatch] richsync misaligned — words matched \(matchedWordLines)/\(lyricsLines.count) (<30%), dropping to line-synced")
                for i in lyricsLines.indices { lyricsLines[i].words = nil }
            } else {
                writeDebugLog("[Musixmatch] richsync words attached to \(matchedWordLines)/\(lyricsLines.count) line(s)")
            }

            // 用于验证是否实际发生了替换
            var didReplaceAnyLine = false

            // subtitle_translated：MxM 返回的目标语言字幕（罗马音或真实翻译）。
            // 按「行起始 offset」对齐到 lyricsLines（richsync/subtitle 行都带 offsetMs 且同源同时间；
            // richsync 与 subtitle 行数不一致时也能对上，多余行自然无翻译）。
            if let subtitleTranslated = subtitle["subtitle_translated"] as? [String: Any],
                let subtitleTranslatedBody = subtitleTranslated["subtitle_body"] as? String,
                let subtitlesTranslated = try? JSONDecoder().decode(
                    [MusixmatchSubtitle].self, from: subtitleTranslatedBody.data(using: .utf8)!
                )
            {
                var translatedByOffset: [Int: String] = [:]
                for st in subtitlesTranslated {
                    let key = Int(st.time.total * 1000)
                    if translatedByOffset[key] == nil { translatedByOffset[key] = st.text }
                }

                if requestedLanguage == romanizationLanguage {
                    // 用户直接选择了罗马音语言：用 MxM 罗马音替换歌词行（按 offset 对齐）
                    for i in 0..<lyricsLines.count {
                        guard let offset = lyricsLines[i].offsetMs,
                              let roma = translatedByOffset[offset], !roma.isEmpty else { continue }
                        lyricsLines[i].content = roma
                        didReplaceAnyLine = true
                    }
                } else if !requestedLanguage.isEmpty {
                    // 用户选择了真实翻译语言：按 offset 对齐附加为翻译层（显示翻译按钮），
                    // 行内容保持原文，交给 toSpotifyLyricsData 做本地罗马化。
                    translation = LyricsTranslationDto(
                        languageCode: requestedLanguage,
                        lines: lyricsLines.map { line -> String in
                            guard let offset = line.offsetMs,
                                  let t = translatedByOffset[offset] else { return "" }
                            return (shouldRemoveMxmInterludeSymbol
                                && t.trimmingCharacters(in: .whitespaces) == "♪")
                                ? "" : t
                        }
                    )
                }
            }
            // 次优先：未选择任何目标语言时，全局罗马化开关开启，
            // 尝试通过翻译接口拿 MxM 罗马音替换歌词行（按 content 匹配，兼容 richsync x 与 subtitle text）。
            // 已选择真实翻译语言时不走这里，避免 MxM 罗马音顶掉本地转换。
            else if isNgzhwmRomanizationEnabled(for: romanizationLanguage),
                requestedLanguage.isEmpty {
                if let translations = try? getTranslations(
                    query.spotifyTrackId,
                    selectedLanguage: romanizationLanguage
                ) {
                    for (original, translationText) in translations {
                        for i in 0..<lyricsLines.count {
                            if lyricsLines[i].content == original {
                                lyricsLines[i].content = translationText
                                didReplaceAnyLine = true
                            }
                        }
                    }
                }
            }

            if shouldRemoveMxmInterludeSymbol {
                for index in lyricsLines.indices {
                    lyricsLines[index].content = cleanedMxmLyricsText(lyricsLines[index].content)
                }
            }

            if didReplaceAnyLine {
                romanized = true
            }

            var romanization = LyricsRomanizationStatus.original

            if romanized {
                romanization = .romanized
            } else if lyricsLines.map({ $0.content }).canBeRomanized
                || subtitleLanguage.isCanBeRomanizedLanguage
            {
                romanization = .canBeRomanized
            }

            let lyricsDto = LyricsDto(
                lines: lyricsLines,
                timeSynced: true,
                romanization: romanization,
                translation: translation,
                languageCode: subtitleLanguage
            )

            writeDebugLog("[Musixmatch] Synced lyrics — \(lyricsDto.lines.count) line(s)")
            lyricsCache.setObject(CachedLyrics(dto: lyricsDto), forKey: cacheKey as NSString)
            return lyricsDto
        }

        if let trackLyricsGet = macroCalls["track.lyrics.get"] as? [String: Any],
            let lyricsMessage = trackLyricsGet["message"] as? [String: Any],
            let lyricsHeader = lyricsMessage["header"] as? [String: Any],
            let lyricsStatusCode = lyricsHeader["status_code"] as? Int
        {

            if lyricsStatusCode == 404 {
                writeDebugLog("[Musixmatch] 404 — no song")
                throw LyricsError.noSuchSong
            }

            if let lyricsBody = lyricsMessage["body"] as? [String: Any],
                let lyrics = lyricsBody["lyrics"] as? [String: Any],
                let lyricsLanguage = lyrics["lyrics_language"] as? String,
                let plainLyrics = lyrics["lyrics_body"] as? String
            {

                if let restricted = lyrics["restricted"] as? Bool, restricted {
                    throw LyricsError.musixmatchRestricted
                }

                let plainLines = plainLyrics
                    .components(separatedBy: "\n")
                    .dropLast()
                    .map { cleanedMxmLyricsText($0.lyricsNoteIfEmpty) }

                let lyricsDto = LyricsDto(
                    lines: plainLines.map { LyricsLineDto(content: $0) },
                    timeSynced: false,
                    romanization: plainLines.canBeRomanized
                        || lyricsLanguage.isCanBeRomanizedLanguage
                        ? .canBeRomanized : .original,
                    languageCode: lyricsLanguage
                )

                writeDebugLog("[Musixmatch] Plain lyrics — \(plainLines.count) line(s)")
                lyricsCache.setObject(CachedLyrics(dto: lyricsDto), forKey: cacheKey as NSString)
                return lyricsDto
            }
        }

        writeDebugLog("[Musixmatch] No usable lyrics")
        throw LyricsError.decodingError
    }
}