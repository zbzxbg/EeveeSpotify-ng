import Foundation
import Combine

class NgzhwmSettingsViewModel: ObservableObject {
    static let removeMxmInterludeSymbolKey = "ngzhwm_removeMxmInterludeSymbol"
    static let disableLyricsFeatureKey = "ngzhwm_disableLyricsFeature"
    static let geniusStrictMatchKey = "ngzhwm_geniusStrictMatch"
    static let stricterJapaneseRomanizationKey = "ngzhwm_stricterJapaneseRomanization"

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
    
    @Published var chineseRomanization: Bool {
        didSet {
            UserDefaults.standard.set(chineseRomanization, forKey: "ngzhwm_chineseRomanization")
        }
    }
    
    @Published var japaneseRomanization: Bool {
        didSet {
            UserDefaults.standard.set(japaneseRomanization, forKey: "ngzhwm_japaneseRomanization")
        }
    }
    
    @Published var koreanRomanization: Bool {
        didSet {
            UserDefaults.standard.set(koreanRomanization, forKey: "ngzhwm_koreanRomanization")
        }
    }
    
    @Published var removeMxmInterludeSymbol: Bool {
        didSet {
            UserDefaults.standard.set(removeMxmInterludeSymbol, forKey: Self.removeMxmInterludeSymbolKey)
        }
    }
    
    @Published var geniusStrictMatch: Bool {
        didSet {
            UserDefaults.standard.set(geniusStrictMatch, forKey: Self.geniusStrictMatchKey)
        }
    }
    
    @Published var stricterJapaneseRomanization: Bool {
        didSet {
            UserDefaults.standard.set(stricterJapaneseRomanization, forKey: Self.stricterJapaneseRomanizationKey)
        }
    }

    init() {
        self.disableLyricsFeature = UserDefaults.standard.bool(forKey: Self.disableLyricsFeatureKey)
        self.multiLevelFallback = UserDefaults.standard.bool(forKey: "ngzhwm_multiLevelLyricsFallback")
        self.chineseRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization")
        self.japaneseRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization")
        self.koreanRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization")
        self.removeMxmInterludeSymbol = UserDefaults.standard.bool(forKey: Self.removeMxmInterludeSymbolKey)
        self.geniusStrictMatch = UserDefaults.standard.bool(forKey: Self.geniusStrictMatchKey)
        self.stricterJapaneseRomanization = UserDefaults.standard.bool(forKey: Self.stricterJapaneseRomanizationKey)
    }
}
