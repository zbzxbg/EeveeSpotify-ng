import SwiftUI
import Combine

extension EeveeLyricsSettingsViewModel {
    func setupBindings() {
        $lyricsOptions
            .map(\.musixmatchLanguage)
            .sink { [weak self] language in
                guard let self = self else { return }
                
                let isValidLanguage = language.isEmpty || language ~= "^[\\w\\d]{2}$"
                
                if isValidLanguage {
                    self.showMusixmatchInvalidLanguageWarning = false
                    MusixmatchLyricsRepository.shared.selectedLanguage = language
                    return
                }
                
                self.showMusixmatchInvalidLanguageWarning = true
            }
            .store(in: &cancellables)
        
        $lyricsOptions
            .map(\.lrclibUrl)
            .map { urlString -> AnyPublisher<LrclibURLState, Never> in
                guard let url = URL(string: urlString) else {
                    return Just(.invalidURL).eraseToAnyPublisher()
                }
                
                if url.host == "lrclib.net" {
                    return Just(.originalURL).eraseToAnyPublisher()
                }
                
                return URLSession.shared.dataTaskPublisher(for: url)
                    .map { _ in
                        LrclibLyricsRepository.shared.apiUrl = urlString
                        return LrclibURLState.ok
                    }
                    .catch { _ in Just(LrclibURLState.unreachableURL) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .assign(to: &$lrclibURLState)
        
        $musixmatchToken
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tokenString in
                guard let self = self else { return }
                
                if let token = self.getMusixmatchTokenFromDebugInfo(tokenString) {
                    self.musixmatchToken = token
                    return
                }
                
                if let token = self.getMusixmatchToken(tokenString) {
                    UserDefaults.musixmatchToken = token
                    writeDebugLog("[Musixmatch] token saved (length \(token.count))")
                } else if !tokenString.isEmpty {
                    // 以前这里是静默失败：输入框显示你粘的内容，UserDefaults 里却仍是旧值（可能是空的），
                    // 于是请求带着空 usertoken 出去，在 Musixmatch 边缘就被拒。
                    writeDebugLog(
                        "[Musixmatch] token rejected — 需要 54 位小写十六进制，实际长度 \(tokenString.count)"
                    )
                }
            }
            .store(in: &cancellables)
        
        $lyricsSource
            .dropFirst()
            .sink { [weak self] newSource in
                guard let self = self else { return }
                
                if newSource == .lrclib {
                    self.lyricsOptions.lrclibUrl = LrclibLyricsRepository.originalApiUrl
                }
                
                UserDefaults.lyricsSource = newSource
            }
            .store(in: &cancellables)
    }
}
