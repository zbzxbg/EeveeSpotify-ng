import Foundation
import Combine

class NgzhwmSettingsViewModel: ObservableObject {
    static let removeMxmInterludeSymbolKey = "ngzhwm_removeMxmInterludeSymbol"
    static let disableLyricsFeatureKey = "ngzhwm_disableLyricsFeature"
    static let neteaseRomajiLocalKey = "ngzhwm_neteaseRomajiLocal"

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

    init() {
        self.disableLyricsFeature = UserDefaults.standard.bool(forKey: Self.disableLyricsFeatureKey)
        self.multiLevelFallback = UserDefaults.standard.bool(forKey: "ngzhwm_multiLevelLyricsFallback")
        self.removeMxmInterludeSymbol = UserDefaults.standard.bool(forKey: Self.removeMxmInterludeSymbolKey)
        self.neteaseRomajiLocal = UserDefaults.standard.bool(forKey: Self.neteaseRomajiLocalKey)
    }
}
