import Orion
import SwiftUI

//

private func loadCustomLyricsForCurrentTrack() throws -> Lyrics {
    guard
        let track = statefulPlayer?.currentTrack() ??
                    nowPlayingScrollViewController?.loadedTrack
        else {
            throw LyricsError.noCurrentTrack
        }
    
    let searchQuery = LyricsSearchQuery(
        title: track.trackTitle(),
        primaryArtist: EeveeSpotify.hookTarget == .lastAvailableiOS14
            ? track.artistTitle()
            : track.artistName(),
        spotifyTrackId: track.trackIdentifier
    )
    
    let options = UserDefaults.lyricsOptions
    let primarySource = UserDefaults.lyricsSource
    
    if primarySource == .notReplaced {
        throw LyricsError.invalidSource
    }
    
    var attempts = [primarySource]
    if options.geniusFallback {
        attempts += lyricsSourceFallbackChain.filter { $0 != primarySource }
    }
    
    lyricsState = LyricsLoadingState()
    
    let requestTimeout: TimeInterval = 2.0  // 每个源最多等2秒
    
    for (index, source) in attempts.enumerated() {
        let isLastAttempt = index == attempts.count - 1
        let semaphore = DispatchSemaphore(value: 0)
        var resultDto: LyricsDto?
        var requestError: Error?
        
        // 在后台线程发起请求（不阻塞当前线程的等待）
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dto = try lyricsRepository(for: source).getLyrics(searchQuery, options: options)
                resultDto = dto
            } catch {
                requestError = error
            }
            semaphore.signal()
        }
        
        // 等待信号，最多等 requestTimeout 秒
        let waitResult = semaphore.wait(timeout: .now() + requestTimeout)
        
        if waitResult == .timedOut {
            // 该源超时，视为失败
            if index == 0 {
                // 主源超时，设置 fallbackError 为超时（便于UI显示）
                lyricsState.fallbackError = .timeout
            }
            if isLastAttempt {
                // 所有源都尝试过，最后一个也超时，抛出超时错误
                throw LyricsError.timeout
            } else {
                continue  // 尝试下一个源
            }
        }
        
        // 正常收到信号，检查结果
        if let dto = resultDto {
            // 成功获取歌词
            lyricsState.isEmpty = dto.lines.isEmpty
            lyricsState.wasRomanized = dto.romanization == .romanized
                || (dto.romanization == .canBeRomanized && options.romanization)
            lyricsState.loadedSuccessfully = true
            return Lyrics.with {
                $0.data = dto.toSpotifyLyricsData(source: source.description)
            }
        } else if let error = requestError {
            // 请求返回错误
            let lyricsError = error as? LyricsError
            if index == 0 {
                lyricsState.fallbackError = lyricsError ?? .unknownError
            }
            
            // 处理 Musixmatch 特定错误（弹出提示）
            switch lyricsError {
            case .invalidMusixmatchToken:
                if !hasShownUnauthorizedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_unauthorized_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownUnauthorizedPopUp = true
                }
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_restricted_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownRestrictedPopUp = true
                }
            default:
                break
            }
            
            if isLastAttempt {
                throw error  // 最后一个源失败，抛出错误
            } else {
                continue    // 继续尝试下一个源
            }
        } else {
            // 理论上不可能（无结果也无错误）
            if isLastAttempt {
                throw LyricsError.unknownError
            } else {
                continue
            }
        }
    }
    
    // 理论上不会执行到这里（因为 attempts 非空，循环内必返回或抛出）
    throw LyricsError.unknownError
}