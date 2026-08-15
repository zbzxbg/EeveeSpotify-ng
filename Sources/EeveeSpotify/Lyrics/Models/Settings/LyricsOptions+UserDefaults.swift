import Foundation

extension UserDefaults {
    @UserDefault(
        key: "lyricsOptions",
        defaultValue: LyricsOptions(
            romanization: false,
            musixmatchLanguage: Locale.current.languageCode ?? "",
            lrclibUrl: LrclibLyricsRepository.originalApiUrl,
            geniusFallback: true
        )
    )
    static var lyricsOptions
}
