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

// 两种回退模式共用：处理 Musixmatch 相关错误弹窗
private func handleLyricsErrorPopUp(_ error: LyricsError?) {
    switch error {
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
    lyricsState = LyricsLoadingState()

    // ngzhwm_multiLevelLyricsFallback 开启 -> 固定顺序多级回退（并发 + 超时）
    // ngzhwm_multiLevelLyricsFallback 关闭（默认）-> 用户选择的单一源 + 可选 Genius 回退
    if UserDefaults.ngzhwm_multiLevelLyricsFallback {

        let attempts: [LyricsSource] = [.musixmatch, .petit, .lrclib, .genius]
        let requestTimeout: TimeInterval = 2.0 // 每个源最多等2秒

        for (index, source) in attempts.enumerated() {
            let isLastAttempt = index == attempts.count - 1
            let semaphore = DispatchSemaphore(value: 0)
            var resultDto: LyricsDto?
            var requestError: Error?

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    resultDto = try lyricsRepository(for: source).getLyrics(searchQuery, options: options)
                } catch {
                    requestError = error
                }
                semaphore.signal()
            }

            let waitResult = semaphore.wait(timeout: .now() + requestTimeout)

            if waitResult == .timedOut {
                if index == 0 { lyricsState.fallbackError = .unknownError }
                if isLastAttempt { throw LyricsError.unknownError } else { continue }
            }

            if let dto = resultDto {
                lyricsState.isEmpty = dto.lines.isEmpty
                lyricsState.wasRomanized = dto.romanization == .romanized
                    || (dto.romanization == .canBeRomanized && options.romanization)
                lyricsState.loadedSuccessfully = true

                return Lyrics.with {
                    $0.data = dto.toSpotifyLyricsData(source: source.description)
                }
            } else if let error = requestError {
                let lyricsError = error as? LyricsError
                if index == 0 { lyricsState.fallbackError = lyricsError ?? .unknownError }
                handleLyricsErrorPopUp(lyricsError)

                if isLastAttempt { throw error } else { continue }
            } else {
                if isLastAttempt { throw LyricsError.unknownError } else { continue }
            }
        }

        throw LyricsError.unknownError

    } else {

        var source = UserDefaults.lyricsSource

        if source == .notReplaced {
            throw LyricsError.invalidSource
        }

        var repository = lyricsRepository(for: source)
        let lyricsDto: LyricsDto

        do {
            lyricsDto = try repository.getLyrics(searchQuery, options: options)
        } catch let error {
            if let error = error as? LyricsError {
                lyricsState.fallbackError = error
                handleLyricsErrorPopUp(error)
            } else {
                lyricsState.fallbackError = .unknownError
            }

            if source == .genius || !options.geniusFallback {
                throw error
            }

            source = .genius
            repository = geniusLyricsRepository
            lyricsDto = try repository.getLyrics(searchQuery, options: options)
        }

        lyricsState.isEmpty = lyricsDto.lines.isEmpty
        lyricsState.wasRomanized = lyricsDto.romanization == .romanized
            || (lyricsDto.romanization == .canBeRomanized && options.romanization)
        lyricsState.loadedSuccessfully = true

        return Lyrics.with {
            $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
        }
    }
}

func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data {
    // 非阻塞状态同步机制（来自版本1，两种回退模式下均保留生效）
    // 解决切歌时 track 状态尚未更新导致的 trackMismatch 问题
    var track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    var trackIdentifier = track?.trackIdentifier ?? ""

    if !trackIdentifier.isEmpty && !originalPath.contains(trackIdentifier) {
        let maxWaitTime: TimeInterval = 0.3 // 设定最大等待时间 300ms
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < maxWaitTime {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

            track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
            trackIdentifier = track?.trackIdentifier ?? ""

            if trackIdentifier.isEmpty || originalPath.contains(trackIdentifier) {
                break
            }
        }
    }

    guard let track = track else {
        throw LyricsError.noCurrentTrack
    }

    if !trackIdentifier.isEmpty && !originalPath.contains(trackIdentifier) {
        throw LyricsError.trackMismatch
    }

    var lyrics = try loadCustomLyricsForCurrentTrack()

    let lyricsColorsSettings = UserDefaults.lyricsColors

    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    } else {
        let extractedColor = switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14:
            track.extractedColorHex()
        default:
            track.metadata()["extracted_color"]
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
