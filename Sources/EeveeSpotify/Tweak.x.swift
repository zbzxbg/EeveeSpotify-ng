import Orion
import EeveeSpotifyC
import UIKit
import Foundation
import os

/// Debug-level unified-log sink。相对 NSLog（默认 .default 级别），这里用真正的
/// .debug 级别，可在 Console.app 中按需过滤。
private let eeveeLogger = Logger(
    subsystem: "com.eeveespotify",
    category: "debug"
)

private func appendLogFile(_ message: String) {
    let logPath = NSTemporaryDirectory() + "eeveespotify_debug.log"
    let timestamp = Date().description
    let logMessage = "[\(timestamp)] \(message)\n"

    if FileManager.default.fileExists(atPath: logPath) {
        if let fileHandle = FileHandle(forWritingAtPath: logPath) {
            fileHandle.seekToEndOfFile()
            if let data = logMessage.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        }
    } else {
        try? logMessage.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

func writeDebugLog(_ message: String) {
    // 受设置开关控制：关闭时既不写统一日志，也不写导出文件。
    guard UserDefaults.enableLogRecording else { return }

    // Console：真正的 debug 级别。
    eeveeLogger.debug("\(message, privacy: .public)")

    // 导出文件：沿用追加到临时文件的既有行为。
    appendLogFile(message)
}

/// 错误级日志：统一日志走 .error 级（可在 Console 按 error/fault 过滤），
/// 导出文件加 [ERROR] 前缀。仍受「启用日志记录」开关控制。
func writeErrorLog(_ message: String) {
    guard UserDefaults.enableLogRecording else { return }

    eeveeLogger.error("\(message, privacy: .public)")

    appendLogFile("[ERROR] \(message)")
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
    static let version = "5.1.1"
    
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
        writeDebugLog("=== EeveeSpotify \(EeveeSpotify.version) starting ===")
        writeDebugLog("[INIT] Spotify: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        writeDebugLog("[INIT] iOS: \(UIDevice.current.systemVersion), Device: \(UIDevice.current.model)")
        writeDebugLog("[INIT] Hook target: \(String(describing: EeveeSpotify.hookTarget))")
        writeDebugLog("[INIT] Patch type: \(String(describing: UserDefaults.patchType))")
        writeDebugLog("[INIT] Lyrics source: \(UserDefaults.lyricsSource.description)")

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
