import Foundation

struct LyricsSearchQuery: Hashable {
    var title: String
    var primaryArtist: String
    var spotifyTrackId: String

    /// Spotify 侧歌曲时长（毫秒）。从 track 的 metadata 字典提取；
    /// 本地文件等拿不到时为 nil，调用方应跳过时长校验。
    var durationMs: Int? = nil
}

