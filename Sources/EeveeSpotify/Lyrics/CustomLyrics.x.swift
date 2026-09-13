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
private let amllTtmlLyricsRepository = AmllTtmlLyricsRepository.shared

private func lyricsRepository(for source: LyricsSource) -> LyricsRepository {
    switch source {
    case .genius: return geniusLyricsRepository
    case .lrclib: return LrclibLyricsRepository.shared
    case .musixmatch: return MusixmatchLyricsRepository.shared
    case .petit: return petitLyricsRepository
    case .spicy: return SpicyLyricsRepository.shared
    case .netease:
        return NeteaseLyricsRepository.shared
    case .amllTtml:
        return amllTtmlLyricsRepository
    case .notReplaced, .multiLevel:
        // Never actually reached — callers filter these out beforehand.
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
        spotifyTrackId: track.trackIdentifier,
        durationMs: track.trackDurationMilliseconds
    )

    let options = UserDefaults.lyricsOptions
    lyricsState = LyricsLoadingState()
    writeDebugLog("[Lyrics] Track \"\(searchQuery.title)\" - \(searchQuery.primaryArtist) (id \(searchQuery.spotifyTrackId))")
    if let durationMs = searchQuery.durationMs {
        writeDebugLog("[Lyrics] Track duration \(durationMs)ms (from metadata)")
    } else {
        writeDebugLog("[Lyrics] Track duration unavailable — NetEase duration gate skipped")
    }

    // lyricsSource == .multiLevel -> 固定顺序多级回退（并发 + 超时）
    // 其它来源 -> 用户选择的单一源 + 可选 Genius 回退
    var source = UserDefaults.lyricsSource
    if source == .multiLevel {

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
                writeDebugLog("[Lyrics] \(source.description) timed out after \(requestTimeout)s")
                // Genius 失败（含超时）不再兜底为空歌词，统一走下面的抛错逻辑
                if index == 0 { lyricsState.fallbackError = .unknownError }
                if isLastAttempt { throw LyricsError.unknownError } else { continue }
            }

            if let dto = resultDto {
                writeDebugLog("[Lyrics] \(source.description) returned \(dto.lines.count) line(s)")
                currentLyricsDto = dto.romanizedForWordByWordIfEnabled()
                currentLyricsVersion += 1
                lyricsState.isEmpty = dto.lines.isEmpty
                lyricsState.wasRomanized = dto.romanization == .romanized
                    || dto.romanization == .canBeRomanized
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

        writeDebugLog("[Lyrics] Single source: \(source.description)")

        if source == .notReplaced {
            throw LyricsError.invalidSource
        }

        // 「AMLL 优先」：先向 AMLL 要逐词歌词，**只接受逐词歌词**，
        // 拿不到就回退到用户在来源选择器里设置的那个源（连同它的相关设置）。
        //
        // 回退目标刻意不是硬编码的：哪个源适合兜底完全取决于地区与语言 ——
        // 日本用户设 PetitLyrics、大陆用户设网易云、其它地区设 SpicyLyrics，
        // 各自回退到自己最合适的地方，不需要我们再维护一份地区判断。
        // 该选项依赖逐词歌词，未开启时视为未勾选。
        let amllPreferred = NgzhwmSettingsViewModel.isAmllPreferred
            && NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
            && source != .amllTtml

        if amllPreferred {
            writeDebugLog("[Lyrics] AMLL preferred — trying AMLL first, fallback target: \(source.description)")

            // 走同一套单源错误处理：记录 fallbackError、弹 MxM 相关弹窗。
            let amllDto = try? requestSingleSource(
                .amllTtml,
                searchQuery: searchQuery,
                options: options,
                recordFallbackError: true
            )

            // ⚠️ 判据是**逐词可用**，不是「有行」。
            //
            // AMLL 的 TTML 里两种数据都可能出现：
            //   · 有 `<span>` 逐词时间轴 → 逐词歌词（要的）
            //   · 只有 `<p begin=...>` 行级时间轴 → 就是一行一句的普通同步歌词
            // 以前这里只判 `!lines.isEmpty`，于是第二种也被当成"AMLL 成功"直接采用：
            // 用户明明开了「AMLL 优先」（只想要逐词），结果拿到一份逐行歌词，
            // 而且它的排版/来源和用户自己设的那个源完全不同 —— 看起来就像"设置没生效"。
            //
            // 现在把判定口径与渲染层对齐（同一个 `hasUsableWordLevelData`）：
            // 行级数据在这里就被判为"不合格"，交给下面用户设置的源去处理。
            // 无时间轴的数据同样过不了这一关（`timeSynced == false`），一并回退。
            if let dto = amllDto, hasUsableWordLevelData(dto) {
                writeDebugLog("[Lyrics] AMLL succeeded — using it (\(dto.lines.count) line(s))")
                return makeLyrics(from: dto, source: .amllTtml)
            }

            // 分开报两种失败原因：日志里能立刻分清是"请求失败"还是"拿到了但不够逐词"。
            if let dto = amllDto {
                let timeline = dto.timeSynced ? "line-or-word timeline" : "no timeline"
                writeDebugLog(
                    "[Lyrics] AMLL returned \(dto.lines.count) line(s) but not word-by-word"
                        + " (\(timeline)) — falling back to \(source.description)"
                )
            } else {
                writeDebugLog(
                    "[Lyrics] AMLL unavailable — falling back to \(source.description) with its own settings"
                )
            }
            // 用户设置的就是 Genius 时不必再走下面的 geniusFallback，否则会重复请求一次。
            let dto = try requestSingleSource(
                source,
                searchQuery: searchQuery,
                options: options,
                recordFallbackError: false,
                allowGeniusFallback: source != .genius
            )
            return makeLyrics(from: dto, source: source)
        }

        let lyricsDto = try requestSingleSource(
            source,
            searchQuery: searchQuery,
            options: options,
            recordFallbackError: true
        )

        return makeLyrics(from: lyricsDto, source: source)
    }
    }

    // MARK: - 单源请求

    /// 按用户设置请求单一来源。保持既有行为不变：
    /// - 该源的错误会写入 `lyricsState.fallbackError`（`recordFallbackError`）并弹 MxM 相关弹窗；
    /// - 非 Genius 源失败且 `options.geniusFallback` 开启时，再用 Genius 重试一次。
    ///
    /// - Parameter allowGeniusFallback: 为 false 时跳过 Genius 兜底。用于
    ///   「AMLL 优先」模式下用户设置本身就是 Genius 的场景，避免重复请求同一个源。
    private func requestSingleSource(
        _ source: LyricsSource,
        searchQuery: LyricsSearchQuery,
        options: LyricsOptions,
        recordFallbackError: Bool,
        allowGeniusFallback: Bool = true
    ) throws -> LyricsDto {
        let repository = source == .genius
            ? geniusLyricsRepository
            : lyricsRepository(for: source)

        do {
            return try repository.getLyrics(searchQuery, options: options)
        } catch let error {
            // 单源模式以前只打一句「failed — falling back to Genius」，具体错误被丢掉，
            // 日志里看不出是网络失败、授权失败还是解析失败。
            writeDebugLog("[Lyrics] \(source.description) failed: \(error)")

            if recordFallbackError {
                if let error = error as? LyricsError {
                    lyricsState.fallbackError = error
                    handleLyricsErrorPopUp(error)
                } else {
                    lyricsState.fallbackError = .unknownError
                }
            }

            // 注意顺序：Genius 失败不再兜底为空歌词（与既有行为一致）——
            // allowGeniusFallback 在用户设置本身就是 Genius 时为 false。
            if !allowGeniusFallback || !options.geniusFallback {
                throw error
            }

            writeDebugLog("[Lyrics] \(source.description) failed — falling back to Genius")
            // Genius 兜底源同样直接抛错，不再兜底为空歌词
            return try geniusLyricsRepository.getLyrics(searchQuery, options: options)
        }
    }

    // MARK: - DTO → Lyrics

    /// 把来源返回的 DTO 转成注入 Spotify 的 `Lyrics`，并同步全局状态
    /// （`currentLyricsDto` / `currentLyricsVersion` / `lyricsState`）。
    private func makeLyrics(from dto: LyricsDto, source: LyricsSource) -> Lyrics {
        lyricsState.isEmpty = dto.lines.isEmpty
        lyricsState.wasRomanized = dto.romanization == .romanized
            || dto.romanization == .canBeRomanized
        lyricsState.loadedSuccessfully = true

        currentLyricsDto = dto.romanizedForWordByWordIfEnabled()
        currentLyricsVersion += 1

        return Lyrics.with {
            $0.data = dto.toSpotifyLyricsData(
                source: source.description,
                useInstrumentalPlaceholder: source != .genius
            )
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

    // 记录最终生效的歌词背景色（原始色或定制色），供逐字 overlay 复用，保证与原生模块同色。
    //
    // ⚠️ 必须在下面那个"清 alpha"之前读：overlay 要的是**原色**，
    // 拿去当自己的兜底底色 / 判断明暗，不能是透明值。
    currentLyricsBackgroundColorARGB = lyrics.colors.backgroundColor

    // ── 交给 Spotify 的那份背景色改成**全透明** ───────────────────────────────
    //
    // 为什么：Spotify 拿这个值去刷原生歌词界面的背景 —— 包括**卡片面板**自己那层。
    // 而我们的层是"歌词视图的子视图"，**子视图永远盖不住父视图自己的背景**
    // （绘制顺序是"父视图的 backgroundColor 先画、子视图后画"），
    // 所以预览卡片顶部那条 39pt（「歌词」+ 分享/展开按钮那一行）永远是专辑纯色。
    //
    // 之前试过四种"盖住它"的办法（往卡片塞背景层 / 清容器底色 / 每帧重清 /
    // 让我们的背景画到 bounds 之外），全都无效 —— 因为问题不在层级，在绘制顺序。
    // 这次改成**让它别画**：把注入值的 alpha 清掉，面板就是透明，
    // 露出来的正好是我们已经铺在歌词区上的模糊封面。
    //
    // 只动 alpha（高 8 位），RGB 原样保留：
    //   · 「歌词」标题与分享/展开按钮是**画在面板背景之上**的独立视图，
    //     颜色不受影响，位置和点击也不变；
    //   · 我们自己的 overlay 用的是上面那个 `currentLyricsBackgroundColorARGB`（原值）。
    let injected = lyrics.colors.backgroundColor
    let transparentBackground = injected & 0x00FF_FFFF
    if transparentBackground != injected {
        lyrics.colors.backgroundColor = transparentBackground
        writeDebugLog(
            String(
                format: "[Lyrics] injected background %08X -> %08X (transparent)",
                injected, transparentBackground
            )
        )
    }

    // 记录歌词提供者，供全屏 overlay 底部展示
    currentLyricsProvider = lyrics.data.providedBy

    return try lyrics.serializedBytes()
}
