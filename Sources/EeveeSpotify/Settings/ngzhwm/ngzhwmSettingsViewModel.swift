import Foundation
import Combine

class NgzhwmSettingsViewModel: ObservableObject {
    static let removeMxmInterludeSymbolKey = "ngzhwm_removeMxmInterludeSymbol"
    static let disableLyricsFeatureKey = "ngzhwm_disableLyricsFeature"
    static let neteaseRomajiLocalKey = "ngzhwm_neteaseRomajiLocal"
    static let neteaseHideTranslationKey = "ngzhwm_neteaseHideTranslation"
    static let wordByWordLyricsKey = "ngzhwm_wordByWordLyrics"
    static let betterWordByWordLyricsKey = "ngzhwm_betterWordByWordLyrics"
    static let amllPreferredKey = "ngzhwm_amllPreferred"
    static let blurredLyricsBackdropKey = "ngzhwm_blurredLyricsBackdrop"
    static let lyricsBackdropMaterialKey = "ngzhwm_lyricsBackdropMaterial"

    static var isLyricsFeatureDisabled: Bool {
        UserDefaults.standard.bool(forKey: disableLyricsFeatureKey)
    }

    /// 设备主语言是否为中文（简体/繁体）。
    static var isChineseDevice: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
    }

    /// 读取带默认值的布尔开关：key 尚未写入时返回 defaultValue，否则返回已存值。
    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? defaultValue
            : UserDefaults.standard.bool(forKey: key)
    }

    static var isWordByWordLyricsEnabled: Bool {
        bool(forKey: wordByWordLyricsKey, defaultValue: true)
    }

    static var isNeteaseHideTranslationEnabled: Bool {
        bool(forKey: neteaseHideTranslationKey, defaultValue: !isChineseDevice)
    }

    /// 「AMLL TTML 优先」：开启后先向 AMLL 要逐词歌词，没正常返回再回退到用户在
    /// 来源选择器里设置的那个源（连同它的相关设置）。
    ///
    /// 之所以回退到「用户自己选的源」而不是硬编码一条回退链：哪个源适合兜底完全
    /// 取决于地区与语言 —— 日本用户设 PetitLyrics、大陆用户设网易云、其它地区设
    /// SpicyLyrics，各自回退到最合适的地方，不需要我们再维护地区判断。
    ///
    /// 默认关闭，已装用户的既有行为不变。
    static var isAmllPreferred: Bool {
        bool(forKey: amllPreferredKey, defaultValue: false)
    }

    /// 「模糊封面背景」：用模糊版专辑封面 + 暗化渐变替换纯色底。
    /// 默认开启（这是「更好的逐词歌词」观感的一部分，可单独关掉回到纯色）。
    static var isLyricsBlurredBackdropEnabled: Bool {
        bool(forKey: blurredLyricsBackdropKey, defaultValue: true)
    }

    /// 在模糊封面之上再叠一层系统材质，压掉大面积模糊的色带。
    static var isLyricsBackdropMaterialEnabled: Bool {
        bool(forKey: lyricsBackdropMaterialKey, defaultValue: true)
    }
}
