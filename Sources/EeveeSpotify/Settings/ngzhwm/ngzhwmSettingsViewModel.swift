import Foundation
import Combine

class NgzhwmSettingsViewModel: ObservableObject {
    static let removeMxmInterludeSymbolKey = "ngzhwm_removeMxmInterludeSymbol"

    
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

    init() {
        self.multiLevelFallback = UserDefaults.standard.bool(forKey: "ngzhwm_multiLevelLyricsFallback")
        self.chineseRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization")
        self.japaneseRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization")
        self.koreanRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization")
        self.removeMxmInterludeSymbol = UserDefaults.standard.bool(forKey: Self.removeMxmInterludeSymbolKey)
    }
}
