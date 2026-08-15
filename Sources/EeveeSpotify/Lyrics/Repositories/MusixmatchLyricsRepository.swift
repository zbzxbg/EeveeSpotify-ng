import Foundation
import UIKit

class MusixmatchLyricsRepository: LyricsRepository {
    private let apiUrl = "https://apic.musixmatch.com"

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
        return "\(query.hashValue)_\(selectedLanguage)"
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

    // 根据歌词语言判断对应的罗马化开关是否打开
    private func isLanguageRomanizationEnabled(_ language: String) -> Bool {
        switch language {
        case let lang where lang.hasPrefix("ja"):
            return UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization")
        case let lang where lang.hasPrefix("zh"):
            return UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization")
        case let lang where lang.hasPrefix("ko"):
            return UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization")
        default:
            return false
        }
    }

    //

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let cacheKey = getCacheKey(for: query)

        if let cached = lyricsCache.object(forKey: cacheKey as NSString) {
            return cached.dto
        }

        var musixmatchQuery = [
            "track_spotify_id": query.spotifyTrackId,
            "subtitle_format": "mxm",
            "q_track": query.title,
            "q_artist": query.primaryArtist,
        ]

        if !selectedLanguage.isEmpty {
            musixmatchQuery["selected_language"] = selectedLanguage
            musixmatchQuery["part"] = "subtitle_translated"
        }

        let data = try perform(
            "/ws/1.1/macro.subtitles.get",
            query: musixmatchQuery
        )

        var romanized = false
        var translation: LyricsTranslationDto? = nil

        let macroCalls = try getMacroCalls(data)

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

            var lyricsLines = subtitles.dropLast().map { subtitle in
                LyricsLineDto(
                    content: subtitle.text.lyricsNoteIfEmpty,
                    offsetMs: Int(subtitle.time.total * 1000)
                )
            }

            lyricsLines.append(
                LyricsLineDto(
                    content: "",
                    offsetMs: Int(subtitles.last!.time.total * 1000)
                )
            )

            var didReplaceAnyLine = false

            // 情况 1：用户直接选择了罗马音语言（例如 rj）
            // 此时不检查任何开关，直接使用返回的罗马音字幕（若能成功解码并替换）
            if selectedLanguage != subtitleLanguage,
                let subtitleTranslated = subtitle["subtitle_translated"] as? [String: Any],
                let subtitleTranslatedBody = subtitleTranslated["subtitle_body"] as? String,
                let subtitlesTranslated = try? JSONDecoder().decode(
                    [MusixmatchSubtitle].self, from: subtitleTranslatedBody.data(using: .utf8)!
                )
            {
                if selectedLanguage == romanizationLanguage {
                    for (index, subtitleTranslated) in subtitlesTranslated.enumerated() {
                        if !subtitleTranslated.text.isEmpty {
                            lyricsLines[index].content = subtitleTranslated.text
                            didReplaceAnyLine = true
                        }
                    }
                    if didReplaceAnyLine {
                        romanized = true
                    }
                } else {
                    // 用户选择了其他翻译语言，作为翻译显示
                    translation = LyricsTranslationDto(
                        languageCode: selectedLanguage,
                        lines: subtitlesTranslated.map { $0.text }
                    )
                }
            }

            // 情况 2：用户未选择罗马音语言，但开启了全局罗马化选项
            // 需要两层开关：全局 + 对应语言开关
            if !romanized, // 避免重复处理
                options.romanization,
                selectedLanguage != romanizationLanguage,
                isLanguageRomanizationEnabled(subtitleLanguage)
            {
                if let translations = try? getTranslations(
                    query.spotifyTrackId,
                    selectedLanguage: romanizationLanguage
                ) {
                    for (original, translation) in translations {
                        for i in 0..<lyricsLines.count {
                            if lyricsLines[i].content == original {
                                lyricsLines[i].content = translation
                                didReplaceAnyLine = true
                            }
                        }
                    }
                    if didReplaceAnyLine {
                        romanized = true
                    }
                }
            }

            var romanization = LyricsRomanizationStatus.original

            if romanized {
                romanization = .romanized
            } else if subtitleLanguage.isCanBeRomanizedLanguage {
                romanization = .canBeRomanized
            }

            let lyricsDto = LyricsDto(
                lines: lyricsLines,
                timeSynced: true,
                romanization: romanization,
                translation: translation
            )

            lyricsCache.setObject(CachedLyrics(dto: lyricsDto), forKey: cacheKey as NSString)
            return lyricsDto
        }

        if let trackLyricsGet = macroCalls["track.lyrics.get"] as? [String: Any],
            let lyricsMessage = trackLyricsGet["message"] as? [String: Any],
            let lyricsHeader = lyricsMessage["header"] as? [String: Any],
            let lyricsStatusCode = lyricsHeader["status_code"] as? Int
        {

            if lyricsStatusCode == 404 {
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

                let lyricsDto = LyricsDto(
                    lines:
                        plainLyrics
                        .components(separatedBy: "\n")
                        .dropLast()
                        .map { LyricsLineDto(content: $0.lyricsNoteIfEmpty) },
                    timeSynced: false,
                    romanization: lyricsLanguage.isCanBeRomanizedLanguage
                        ? .canBeRomanized : .original
                )

                lyricsCache.setObject(CachedLyrics(dto: lyricsDto), forKey: cacheKey as NSString)
                return lyricsDto
            }
        }

        throw LyricsError.decodingError
    }
}