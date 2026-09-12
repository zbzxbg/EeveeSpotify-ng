import SwiftUI
import Combine

class EeveeLyricsSettingsViewModel: ObservableObject {
    @Published var lyricsSource = UserDefaults.lyricsSource
    
    @Published var lyricsOptions = UserDefaults.lyricsOptions {
        didSet { UserDefaults.lyricsOptions = lyricsOptions }
    }
    
    @Published var chineseRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization") {
        didSet { UserDefaults.standard.set(chineseRomanization, forKey: "ngzhwm_chineseRomanization") }
    }
    @Published var japaneseRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization") {
        didSet { UserDefaults.standard.set(japaneseRomanization, forKey: "ngzhwm_japaneseRomanization") }
    }
    @Published var koreanRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization") {
        didSet { UserDefaults.standard.set(koreanRomanization, forKey: "ngzhwm_koreanRomanization") }
    }
    
    @Published var wordByWordLyrics = NgzhwmSettingsViewModel.isWordByWordLyricsEnabled {
        didSet {
            UserDefaults.standard.set(
                wordByWordLyrics,
                forKey: NgzhwmSettingsViewModel.wordByWordLyricsKey
            )
        }
    }
    
    @Published var betterWordByWordLyrics = NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled {
        didSet {
            UserDefaults.standard.set(
                betterWordByWordLyrics,
                forKey: NgzhwmSettingsViewModel.betterWordByWordLyricsKey
            )
        }
    }
    
    @Published var amllPreferred = NgzhwmSettingsViewModel.isAmllPreferred {
        didSet {
            UserDefaults.standard.set(
                amllPreferred,
                forKey: NgzhwmSettingsViewModel.amllPreferredKey
            )
        }
    }
    
    // 注：背景相关（模糊封面 / 系统材质）**没有** Published 属性 ——
    // 它们不是用户可选项，而是跟随「更好的逐词歌词」自动启用。
    // 见 NgzhwmSettingsViewModel.isLyricsBlurredBackdropEnabled。
    
    @Published var disableLyricsFeature = UserDefaults.standard.bool(
        forKey: NgzhwmSettingsViewModel.disableLyricsFeatureKey
    ) {
        didSet {
            UserDefaults.standard.set(
                disableLyricsFeature,
                forKey: NgzhwmSettingsViewModel.disableLyricsFeatureKey
            )
        }
    }
    
    @Published var removeMxmInterludeSymbol = UserDefaults.standard.bool(
        forKey: NgzhwmSettingsViewModel.removeMxmInterludeSymbolKey
    ) {
        didSet {
            UserDefaults.standard.set(
                removeMxmInterludeSymbol,
                forKey: NgzhwmSettingsViewModel.removeMxmInterludeSymbolKey
            )
        }
    }
    
    @Published var neteaseRomajiLocal = UserDefaults.standard.bool(
        forKey: NgzhwmSettingsViewModel.neteaseRomajiLocalKey
    ) {
        didSet {
            UserDefaults.standard.set(
                neteaseRomajiLocal,
                forKey: NgzhwmSettingsViewModel.neteaseRomajiLocalKey
            )
        }
    }
    
    @Published var neteaseHideTranslation = NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled {
        didSet {
            UserDefaults.standard.set(
                neteaseHideTranslation,
                forKey: NgzhwmSettingsViewModel.neteaseHideTranslationKey
            )
        }
    }
    
    @Published var musixmatchToken = UserDefaults.musixmatchToken
    @Published var isRequestingMusixmatchToken = false
    @Published var musixmatchTokenInputAlertPublisher = PassthroughSubject<Bool, Never>()
    var isMusixmatchTokenValid: Bool { getMusixmatchToken(musixmatchToken) != nil }
    
    @Published var showMusixmatchInvalidLanguageWarning = false
    @Published var lrclibURLState = LrclibURLState.default
    
    var animationValues: [AnyHashable] {
        [
            lyricsSource,
            lyricsOptions,
            betterWordByWordLyrics,
            wordByWordLyrics,
            amllPreferred,
            disableLyricsFeature,
            removeMxmInterludeSymbol,
            neteaseRomajiLocal,
            neteaseHideTranslation,
            isMusixmatchTokenValid,
            isRequestingMusixmatchToken,
            lrclibURLState,
            showMusixmatchInvalidLanguageWarning
        ]
    }
    
    var cancellables = Set<AnyCancellable>()

    init() {
        setupBindings()
    }
    
    func getMusixmatchTokenFromDebugInfo(_ debugInfo: String) -> String? {
        if let match = debugInfo.firstMatch("\\[UserToken\\]: ([a-f0-9]+)"),
            let tokenRange = Range(match.range(at: 1), in: debugInfo) {
            return String(debugInfo[tokenRange])
        }
        
        return nil
    }
    
    func getMusixmatchToken(_ input: String) -> String? {
        if input ~= "^[a-f0-9]{54}$" {
            return input
        }
        
        return nil
    }
    
    func requestAnonymousMusixmatchToken() {
        guard !isRequestingMusixmatchToken else { return }
        isRequestingMusixmatchToken = true
                
        AnonymousTokenHelper.requestAnonymousMusixmatchToken()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isRequestingMusixmatchToken = false
                
                switch completion {
                case .failure(let error):
                    let message: String
                    if error is AnonymousTokenError {
                        message = "anonymous_token_request_failed".localized
                    } else {
                        message = error.localizedDescription
                    }
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: message,
                        buttonText: "OK".uiKitLocalized
                    )
                case .finished:
                    break
                }
            }, receiveValue: { [weak self] token in
                self?.musixmatchToken = token
            })
            .store(in: &cancellables)
    }
}
