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
        guard UserDefaults.lyricsOptions.romanization else {
            return false
        }

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
        let options = UserDefaults.lyricsOptions
        let romanizationSettings = [
            options.romanization,
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

            // 用于验证是否实际发生了替换
            var didReplaceAnyLine = false

            // subtitle_translated：MxM 返回的目标语言字幕（罗马音或真实翻译）
            if let subtitleTranslated = subtitle["subtitle_translated"] as? [String: Any],
                let subtitleTranslatedBody = subtitleTranslated["subtitle_body"] as? String,
                let subtitlesTranslated = try? JSONDecoder().decode(
                    [MusixmatchSubtitle].self, from: subtitleTranslatedBody.data(using: .utf8)!
                )
            {
                if requestedLanguage == romanizationLanguage {
                    // 用户直接选择了罗马音语言：用 MxM 罗马音替换歌词行
                    for (index, subtitleTranslated) in subtitlesTranslated.enumerated() {
                        if !subtitleTranslated.text.isEmpty {
                            lyricsLines[index].content = subtitleTranslated.text
                            didReplaceAnyLine = true
                        }
                    }
                } else if !requestedLanguage.isEmpty {
                    // 用户选择了真实翻译语言：附加为翻译层（显示翻译按钮），
                    // 行内容保持原文，交给 toSpotifyLyricsData 做本地罗马化，
                    // 这样主歌词是本地转换的罗马字，翻译层是 MxM 返回的翻译。
                    translation = LyricsTranslationDto(
                        languageCode: requestedLanguage,
                        lines: subtitlesTranslated.map { $0.text }
                    )
                }
            }
            // 次优先：未选择任何目标语言时，全局罗马化开关开启，
            // 尝试通过翻译接口拿 MxM 罗马音替换歌词行。
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

                lyricsCache.setObject(CachedLyrics(dto: lyricsDto), forKey: cacheKey as NSString)
                return lyricsDto
            }
        }

        throw LyricsError.decodingError
    }
}