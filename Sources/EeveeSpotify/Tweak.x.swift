import Orion
import EeveeSpotifyC
import UIKit
import os

/// 统一 debug 日志出口（SpicyLyrics 等歌词仓库使用）。
/// os.Logger 的 .debug 级别在 Console.app 默认不显示，可按需过滤。
private let eeveeDebugLogger = Logger(
    subsystem: "com.eeveespotify",
    category: "debug"
)

func writeDebugLog(_ message: String) {
    eeveeDebugLogger.debug("\(message, privacy: .public)")
}

func exitApplication() {
    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
        exit(EXIT_SUCCESS)
    }
}

struct BasePremiumPatchingGroup: HookGroup { }

struct IOS14PremiumPatchingGroup: HookGroup { }
struct NonIOS14PremiumPatchingGroup: HookGroup { }
struct IOS14And15PremiumPatchingGroup: HookGroup { }
struct LatestPremiumPatchingGroup: HookGroup { }

func activatePremiumPatchingGroup() {
    BasePremiumPatchingGroup().activate()
    
    if EeveeSpotify.hookTarget == .lastAvailableiOS14 {
        IOS14PremiumPatchingGroup().activate()
    }
    else {
        NonIOS14PremiumPatchingGroup().activate()
        
        if EeveeSpotify.hookTarget == .lastAvailableiOS15 {
            IOS14And15PremiumPatchingGroup().activate()
        }
        else {
            LatestPremiumPatchingGroup().activate()
        }
    }
}

struct EeveeSpotify: Tweak {
    static let version = "3.0.0"
    
    static var hookTarget: VersionHookTarget {
        let version = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String
        
        switch version {
        case "9.0.48":
            return .lastAvailableiOS15
        case "8.9.8":
            return .lastAvailableiOS14
        default:
            return .latest
        }
    }
    
    init() {
        if UserDefaults.experimentsOptions.showInstagramDestination {
            InstgramDestinationGroup().activate()
        }
        
        if UserDefaults.darkPopUps {
            DarkPopUps().activate()
        }
        
        if UserDefaults.patchType.isPatching {
            activatePremiumPatchingGroup()
        }
        
        if UserDefaults.lyricsSource.isReplacingLyrics {
            BaseLyricsGroup().activate()
            
            if EeveeSpotify.hookTarget == .latest {
                ModernLyricsGroup().activate()
            }
            else {
                LegacyLyricsGroup().activate()
            }
        }
    }
}
