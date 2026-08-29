import Foundation
import Combine

class NgzhwmSettingsViewModel: ObservableObject {
    static let removeMxmInterludeSymbolKey = "ngzhwm_removeMxmInterludeSymbol"
    static let disableLyricsFeatureKey = "ngzhwm_disableLyricsFeature"
    static let neteaseRomajiLocalKey = "ngzhwm_neteaseRomajiLocal"
    static let neteaseHideTranslationKey = "ngzhwm_neteaseHideTranslation"
    static let wordByWordLyricsKey = "ngzhwm_wordByWordLyrics"

    static var isLyricsFeatureDisabled: Bool {
        UserDefaults.standard.bool(forKey: disableLyricsFeatureKey)
    }

    @Published var disableLyricsFeature: Bool {
        didSet {
            UserDefaults.standard.set(disableLyricsFeature, forKey: Self.disableLyricsFeatureKey)
        }
    }

    @Published var multiLevelFallback: Bool {
        didSet {
            UserDefaults.standard.set(multiLevelFallback, forKey: "ngzhwm_multiLevelLyricsFallback")
        }
    }
    
    @Published var removeMxmInterludeSymbol: Bool {
        didSet {
            UserDefaults.standard.set(removeMxmInterludeSymbol, forKey: Self.removeMxmInterludeSymbolKey)
        }
    }
    
    @Published var neteaseRomajiLocal: Bool {
        didSet {
            UserDefaults.standard.set(neteaseRomajiLocal, forKey: Self.neteaseRomajiLocalKey)
        }
    }
    
    @Published var neteaseHideTranslation: Bool {
        didSet {
            UserDefaults.standard.set(neteaseHideTranslation, forKey: Self.neteaseHideTranslationKey)
        }
    }
    
    @Published var wordByWordLyrics: Bool {
        didSet {
            UserDefaults.standard.set(wordByWordLyrics, forKey: Self.wordByWordLyricsKey)
        }
    }

    init() {
        self.disableLyricsFeature = UserDefaults.standard.bool(forKey: Self.disableLyricsFeatureKey)
        self.multiLevelFallback = UserDefaults.standard.bool(forKey: "ngzhwm_multiLevelLyricsFallback")
        self.removeMxmInterludeSymbol = UserDefaults.standard.bool(forKey: Self.removeMxmInterludeSymbolKey)
        self.neteaseRomajiLocal = UserDefaults.standard.bool(forKey: Self.neteaseRomajiLocalKey)
        self.neteaseHideTranslation = UserDefaults.standard.bool(forKey: Self.neteaseHideTranslationKey)
        self.wordByWordLyrics = UserDefaults.standard.bool(forKey: Self.wordByWordLyricsKey)
    }
}
