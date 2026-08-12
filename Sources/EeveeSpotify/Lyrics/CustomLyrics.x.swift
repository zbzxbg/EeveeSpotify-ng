import Orion
import SwiftUI

//

struct BaseLyricsGroup: HookGroup { }

struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }

var lyricsState = LyricsLoadingState()

var hasShownRestrictedPopUp = false
var hasShownUnauthorizedPopUp = false

private let geniusLyricsRepository = GeniusLyricsRepository()
private let petitLyricsRepository = PetitLyricsRepository()

// Fixed fallback priority used when the primary source fails.
// The user's selected source (UserDefaults.lyricsSource) is always
// tried first; on failure, the remaining sources here are tried in
// this order (whichever one was already the primary is skipped).
private let lyricsSourceFallbackChain: [LyricsSource] = [.musixmatch, .petit, .lrclib, .genius]

//

private func lyricsRepository(for source: LyricsSource) -> LyricsRepository {
    switch source {
    case .genius:
        return geniusLyricsRepository
    case .lrclib:
        return LrclibLyricsRepository.shared
    case .musixmatch:
        return MusixmatchLyricsRepository.shared
    case .petit:
        return petitLyricsRepository
    case .notReplaced:
        // Never actually reached — callers filter this out beforehand.
        return geniusLyricsRepository
    }
}

// ========== 修改后的 loadCustomLyricsForCurrentTrack（串行 + 2秒超时） ==========
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
    
    // Attempt order: primary source first, then the rest of the chain
    // (only if Genius Fallback is enabled — this option now gates the
    // whole chain, not just the final Genius step).
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
                // 主源超时，设置 fallbackError 为超时（但 LyricsError 可能没有 .timeout，改用 .unknownError）
                lyricsState.fallbackError = .unknownError
            }
            if isLastAttempt {
                // 所有源都尝试过，最后一个也超时，抛出超时错误（同样使用 .unknownError）
                throw LyricsError.unknownError
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
                    // 直接调用，不加 DispatchQueue.main.async（因为 showPopUp 内部已处理）
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

// ========== getLyricsDataForCurrentTrack（保持不变） ==========
func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data {
    guard
        let track = statefulPlayer?.currentTrack() ??
                    nowPlayingScrollViewController?.loadedTrack
        else {
            throw LyricsError.noCurrentTrack
        }
    
    let trackIdentifier = track.trackIdentifier
    
    if !trackIdentifier.isEmpty && !originalPath.contains(trackIdentifier) {
        throw LyricsError.trackMismatch
    }
    
    var lyrics = try loadCustomLyricsForCurrentTrack()
    
    let lyricsColorsSettings = UserDefaults.lyricsColors
    
    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    else {
        let extractedColor = switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14:
            track.extractedColorHex()
        default:
            track.metadata()["extracted_color"]
        }
        
        var color: Color
        
        if lyricsColorsSettings.useStaticColor {
            color = Color(hex: lyricsColorsSettings.staticColor)
        }
        else if let extractedColor = extractedColor {
            color = Color(hex: extractedColor)
                .normalized(lyricsColorsSettings.normalizationFactor)
        }
        else if let uiColor = backgroundViewModel?.color() {
            color = Color(uiColor)
                .normalized(lyricsColorsSettings.normalizationFactor)
        }
        else {
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