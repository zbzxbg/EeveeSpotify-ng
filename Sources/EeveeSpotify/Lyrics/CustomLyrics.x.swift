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
    case .spicy: return SpicyLyricsRepository.shared
    case .netease:
        return NeteaseLyricsRepository.shared
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
    writeDebugLog("[Lyrics] Track \"\(searchQuery.title)\" - \(searchQuery.primaryArtist) (id \(searchQuery.spotifyTrackId))")

    // ngzhwm_multiLevelLyricsFallback 开启 -> 固定顺序多级回退（并发 + 超时）
    // ngzhwm_multiLevelLyricsFallback 关闭（默认）-> 用户选择的单一源 + 可选 Genius 回退
    if UserDefaults.standard.bool(forKey: "ngzhwm_multiLevelLyricsFallback") {

        writeDebugLog("[Lyrics] Multi-level fallback enabled")
        let attempts: [LyricsSource] = [.musixmatch, .petit, .lrclib, .genius]
        for (index, source) in attempts.enumerated() {
            writeDebugLog("[Lyrics] Attempt \(index + 1)/\(attempts.count): \(source.description)")
            let isLastAttempt = index == attempts.count - 1
            let requestTimeout: TimeInterval =
                source == .musixmatch || source == .petit ? 5.0 : 3.0

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
                // Genius 失败（含超时）不再兜底为空歌词，统一走下面的抛错逻辑
                if index == 0 { lyricsState.fallbackError = .unknownError }
                if isLastAttempt { throw LyricsError.unknownError } else { continue }
            }

            if let dto = resultDto {
                writeDebugLog("[Lyrics] \(source.description) returned \(dto.lines.count) line(s)")
                lyricsState.isEmpty = dto.lines.isEmpty
                lyricsState.wasRomanized = dto.romanization == .romanized
                    || (dto.romanization == .canBeRomanized && options.romanization)
                lyricsState.loadedSuccessfully = true

                return Lyrics.with {
                    $0.data = dto.toSpotifyLyricsData(
                        source: source.description,
                        useInstrumentalPlaceholder: source != .genius
                    )
                }
            } else if let error = requestError {
                writeDebugLog("[Lyrics] \(source.description) failed: \(error)")
                let lyricsError = error as? LyricsError
                if source != .genius {
                    if index == 0 { lyricsState.fallbackError = lyricsError ?? .unknownError }
                    handleLyricsErrorPopUp(lyricsError)
                }

                // Genius 失败（含查无此曲）直接抛出，不再兜底为空歌词
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

    } else {

        var source = UserDefaults.lyricsSource
        writeDebugLog("[Lyrics] Single source: \(source.description)")

        if source == .notReplaced {
            throw LyricsError.invalidSource
        }

        var repository = lyricsRepository(for: source)
        let lyricsDto: LyricsDto

        do {
            lyricsDto = try repository.getLyrics(searchQuery, options: options)
        } catch let error {
            if source == .genius {
                // Genius 失败（含查无此曲）直接抛出，不再兜底为空歌词
                throw error
            } else {
                if let error = error as? LyricsError {
                    lyricsState.fallbackError = error
                    handleLyricsErrorPopUp(error)
                } else {
                    lyricsState.fallbackError = .unknownError
                }

                if !options.geniusFallback {
                    throw error
                }

                writeDebugLog("[Lyrics] \(source.description) failed — falling back to Genius")
                source = .genius
                repository = geniusLyricsRepository
                // Genius 兜底源同样直接抛错，不再兜底为空歌词
                lyricsDto = try repository.getLyrics(searchQuery, options: options)
            }
        }

        lyricsState.isEmpty = lyricsDto.lines.isEmpty
        lyricsState.wasRomanized = lyricsDto.romanization == .romanized
            || (lyricsDto.romanization == .canBeRomanized && options.romanization)
        lyricsState.loadedSuccessfully = true

        return Lyrics.with {
            $0.data = lyricsDto.toSpotifyLyricsData(
                source: source.description,
                useInstrumentalPlaceholder: source != .genius
            )
        }
    }
}

func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data {
    writeDebugLog("[Lyrics] Request for \(originalPath)")
    guard !NgzhwmSettingsViewModel.isLyricsFeatureDisabled else {
        writeDebugLog("[Lyrics] Feature disabled — refusing")
        throw LyricsError.invalidSource
    }

    // 非阻塞状态同步机制（来自版本1，两种回退模式下均保留生效）
    // 解决启动/切歌时 track 状态尚未更新导致的 noCurrentTrack 与 trackMismatch 问题。
    var track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    var trackIdentifier = track?.trackIdentifier ?? ""
    let maxWaitTime: TimeInterval = 1.0
    let startTime = Date()

    while Date().timeIntervalSince(startTime) < maxWaitTime {
        let isReady = track != nil &&
            (trackIdentifier.isEmpty || originalPath.contains(trackIdentifier))
        if isReady {
            break
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        trackIdentifier = track?.trackIdentifier ?? ""
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
        writeDebugLog("[Lyrics] Using original colors")
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
