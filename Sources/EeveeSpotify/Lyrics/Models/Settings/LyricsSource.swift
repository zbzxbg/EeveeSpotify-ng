import Foundation

enum LyricsSource: Int, CaseIterable, CustomStringConvertible {
    case genius
    case lrclib
    case musixmatch
    case petit
    case notReplaced
    // 新增分支追加在末尾，避免改变既有 rawValue 导致已存设置错位。
    case spicy
    case netease
    /// 多级回退：不是单一来源，而是固定顺序的链路（Mxm → PL → LRC → Gen）。
    /// 作为来源选择器里的一项，与具体来源互斥。
    case multiLevel
    /// AMLL：提供高质量逐词歌词与丰富的歌词结构（amll.dev）。
    /// 追加在末尾，避免改变既有 rawValue。
    case amllTtml
    
    static var allCases: [LyricsSource] {
        return [.genius, .lrclib, .amllTtml, .musixmatch, .petit, .spicy, .netease, .multiLevel]
    }

    // swift 5.8 compatible
    var description: String {
    switch self {
    case .genius:
        return "Genius"
    case .lrclib:
        return "LRCLIB"
    case .musixmatch:
        return "Musixmatch"
    case .petit:
        return "PetitLyrics"
    case .notReplaced:
        return "Spotify"
    case .spicy:
        return "SpicyLyrics"
    case .netease:
        return "NetEase"
    case .multiLevel:
        return "ngzhwm_multi_level_fallback".localized
    case .amllTtml:
        return "AMLL"
    }
    }

    
    var isReplacingLyrics: Bool { self != .notReplaced }
    
    static var defaultSource: LyricsSource {
        Locale.isInRegion("JP", orHasLanguage: "ja")
            ? .petit
            : .spicy
    }
}
