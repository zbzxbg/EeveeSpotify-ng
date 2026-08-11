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
    
    for (index, source) in attempts.enumerated() {
        let isLastAttempt = index == attempts.count - 1
        
        do {
            let lyricsDto = try lyricsRepository(for: source).getLyrics(searchQuery, options: options)
            
            lyricsState.isEmpty = lyricsDto.lines.isEmpty
            
            lyricsState.wasRomanized = lyricsDto.romanization == .romanized
                || (lyricsDto.romanization == .canBeRomanized && options.romanization)
            
            lyricsState.loadedSuccessfully = true
            
            return Lyrics.with {
                $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
            }
        }
        catch let error {
            let lyricsError = error as? LyricsError
            
            // Keep the *first* (primary) failure reason for the UI,
            // same as the original single-fallback behavior.
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
                    
                    hasShownUnauthorizedPopUp.toggle()
                }
                
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: "musixmatch_restricted_popup".localized,
                        buttonText: "OK".uiKitLocalized
                    )
                    
                    hasShownRestrictedPopUp.toggle()
                }
                
            default:
                break
            }
            
            if isLastAttempt {
                throw error
            }
            
            // Otherwise fall through to the next source in the chain.
        }
    }
    
    // Unreachable: `attempts` always has at least one element, and the
    // loop above returns or throws on its final iteration.
    throw LyricsError.unknownError
}

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
