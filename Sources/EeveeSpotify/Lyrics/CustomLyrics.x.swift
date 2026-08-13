import Orion
import SwiftUI 

struct BaseLyricsGroup: HookGroup { }
struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }

var lyricsState = LyricsLoadingState()
var hasShownRestrictedPopUp = false
var hasShownUnauthorizedPopUp = false

private let geniusLyricsRepository = GeniusLyricsRepository()
private let petitLyricsRepository = PetitLyricsRepository()

// 不再使用的回退链定义（保留仅为兼容，实际已改为函数内固定顺序）
// private let lyricsSourceFallbackChain: [LyricsSource] = [.musixmatch, .petit, .lrclib, .genius]

private func lyricsRepository(for source: LyricsSource) -> LyricsRepository { 
    switch source { 
    case .genius: return geniusLyricsRepository 
    case .lrclib: return LrclibLyricsRepository.shared 
    case .musixmatch: return MusixmatchLyricsRepository.shared 
    case .petit: return petitLyricsRepository 
    case .notReplaced: 
        // Never actually reached — callers filter this out beforehand.
        return geniusLyricsRepository 
    } 
}

private func loadCustomLyricsForCurrentTrack() throws -> Lyrics { 
    guard let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack else { 
        throw LyricsError.noCurrentTrack 
    } 
    
    let searchQuery = LyricsSearchQuery( 
        title: track.trackTitle(), 
        primaryArtist: EeveeSpotify.hookTarget == .lastAvailableiOS14 ? track.artistTitle() : track.artistName(), 
        spotifyTrackId: track.trackIdentifier 
    ) 
    
    let options = UserDefaults.lyricsOptions
    
    // 强制使用固定顺序：Musixmatch -> Petit -> LRCLIB -> Genius
    let attempts: [LyricsSource] = [.musixmatch, .petit, .lrclib, .genius] 
    lyricsState = LyricsLoadingState() 
    
    let requestTimeout: TimeInterval = 2.0 // 每个源最多等2秒
    
    for (index, source) in attempts.enumerated() { 
        let isLastAttempt = index == attempts.count - 1 
        let semaphore = DispatchSemaphore(value: 0) 
        var resultDto: LyricsDto? 
        var requestError: Error? 
        
        DispatchQueue.global(qos: .userInitiated).async { 
            do { 
                let dto = try lyricsRepository(for: source).getLyrics(searchQuery, options: options) 
                resultDto = dto 
            } catch { 
                requestError = error 
            } 
            semaphore.signal() 
        } 
        
        let waitResult = semaphore.wait(timeout: .now() + requestTimeout) 
        
        if waitResult == .timedOut { 
            if index == 0 { 
                lyricsState.fallbackError = .unknownError 
            } 
            if isLastAttempt { 
                throw LyricsError.unknownError 
            } else { 
                continue 
            } 
        } 
        
        if let dto = resultDto { 
            lyricsState.isEmpty = dto.lines.isEmpty 
            lyricsState.wasRomanized = dto.romanization == .romanized || (dto.romanization == .canBeRomanized && options.romanization) 
            lyricsState.loadedSuccessfully = true 
            
            return Lyrics.with { 
                $0.data = dto.toSpotifyLyricsData(source: source.description) 
            } 
        } else if let error = requestError { 
            let lyricsError = error as? LyricsError 
            
            if index == 0 { 
                lyricsState.fallbackError = lyricsError ?? .unknownError 
            } 
            
            switch lyricsError { 
            case .invalidMusixmatchToken: 
                if !hasShownUnauthorizedPopUp { 
                    PopUpHelper.showPopUp( 
                        delayed: false, 
                        message: "musixmatch_unauthorized_popup".localized, 
                        buttonText: "OK".uiKitLocalized 
                    ) 
                    hasShownUnauthorizedPopUp = true 
                } 
            case .musixmatchRestricted: 
                if !hasShownRestrictedPopUp { 
                    PopUpHelper.showPopUp( 
                        delayed: false, 
                        message: "musixmatch_restricted_popup".localized, 
                        buttonText: "OK".uiKitLocalized 
                    ) 
                    hasShownRestrictedPopUp = true 
                } 
            default: 
                break 
            } 
            
            if isLastAttempt { 
                throw error 
            } else { 
                continue 
            } 
        } else { 
            if isLastAttempt { 
                throw LyricsError.unknownError 
            } else { 
                continue 
            } 
        } 
    } 
    
    throw LyricsError.unknownError 
}

func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data { 
    // ==========================================
    // 🟢 修改点：非阻塞状态同步机制
    // 解决切歌时 track 状态尚未更新导致的 trackMismatch 问题
    // ==========================================
    var track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    var trackIdentifier = track?.trackIdentifier ?? ""
    
    // 如果发现不匹配，说明正在切歌，状态尚未同步。开始进行非阻塞核查。
    if !trackIdentifier.isEmpty && !originalPath.contains(trackIdentifier) {
        let maxWaitTime: TimeInterval = 0.3 // 设定最大等待时间 300ms
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            // 使用 RunLoop 让出时间片，允许 Spotify 内部完成状态同步
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            
            // 重新尝试获取状态
            track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
            trackIdentifier = track?.trackIdentifier ?? ""
            
            // 如果状态同步成功（或者某些无 ID 的歌曲），跳出循环
            if trackIdentifier.isEmpty || originalPath.contains(trackIdentifier) {
                break
            }
        }
    }
    
    guard let finalTrack = track else { 
        throw LyricsError.noCurrentTrack 
    } 
    
    let trackIdentifier = finalTrack.trackIdentifier
    // 如果经过了 300ms 等待依然不匹配，说明原请求已过期（例如快速连切），直接抛出错误
    if !trackIdentifier.isEmpty && !originalPath.contains(trackIdentifier) { 
        throw LyricsError.trackMismatch 
    }
    // ==========================================
    
    var lyrics = try loadCustomLyricsForCurrentTrack() 
    
    let lyricsColorsSettings = UserDefaults.lyricsColors 
    
    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics { 
        lyrics.colors = originalLyrics.colors 
    } else { 
        let extractedColor = switch EeveeSpotify.hookTarget { 
        case .lastAvailableiOS14: 
            finalTrack.extractedColorHex() 
        default: 
            finalTrack.metadata()["extracted_color"] 
        } 
        
        var color: Color 
        if lyricsColorsSettings.useStaticColor { 
            color = Color(hex: lyricsColorsSettings.staticColor) 
        } else if let extractedColor = extractedColor { 
            color = Color(hex: extractedColor) 
                .normalized(lyricsColorsSettings.normalizationFactor) 
        } else if let uiColor = backgroundViewModel?.color() { 
            color = Color(uiColor) 
                .normalized(lyricsColorsSettings.normalizationFactor) 
        } else { 
            color = Color.gray 
        } 
        
        lyrics.colors = LyricsColors.with { 
            $0.backgroundColor = color.uInt32 
            $0.lineColor = Color.black.uInt32 
            $0.activeLineColor = Color.white.uInt32 
        } 
    } 
    
    return try lyrics.serializedBytes() 
}
