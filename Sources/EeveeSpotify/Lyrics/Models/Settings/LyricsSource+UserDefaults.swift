import Foundation

extension UserDefaults {
    private static let lyricsSourceKey = "lyricsSource"
    /// 旧版「歌词多级回退」独立开关的 key，仅用于一次性迁移。
    private static let legacyMultiLevelFallbackKey = "ngzhwm_multiLevelLyricsFallback"
    
    static var lyricsSource: LyricsSource {
        get {
            // 一次性迁移：旧的「歌词多级回退」独立开关已并入来源选择器。
            // 若用户此前开着该开关，则切换到 .multiLevel 并清掉旧 key。
            if container.bool(forKey: legacyMultiLevelFallbackKey) {
                container.set(false, forKey: legacyMultiLevelFallbackKey)
                container.set(LyricsSource.multiLevel.rawValue, forKey: lyricsSourceKey)
                return .multiLevel
            }

            if let rawValue = container.object(forKey: lyricsSourceKey) as? Int {
                return LyricsSource(rawValue: rawValue)!
            }

            return LyricsSource.defaultSource
        }
        set (newSource) {
            container.set(newSource.rawValue, forKey: lyricsSourceKey)
        }
    }
}
