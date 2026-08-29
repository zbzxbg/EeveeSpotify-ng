import Orion
import UIKit
import ObjectiveC

// ⚠️ 临时探针 round 2（确认签名后删除本文件）：
// 用 runtime 枚举 StatefulPlayer 及其关联对象（曲目、歌词滚动 view model 等）的
// 全部 @objc 方法名 + 类型编码（如 d16@0:8 = double 无参；v24@0:8d16 = void+double 参数），
// 一次把进度/seek 的确切位置和签名钉死。

private var playerProbeHasRun = false

func runPlayerProbe() {
    guard !playerProbeHasRun else { return }

    guard let player = statefulPlayer as? NSObject else {
        writeDebugLog("[Probe] statefulPlayer nil — retry next track")
        return
    }
    playerProbeHasRun = true

    writeDebugLog("[Probe] ===== round 2 =====")

    // 1) 玩家类方法全枚举（含父类链）
    dumpMethods(of: type(of: player), label: "StatefulPlayerImpl")

    // 2) 当前曲目
    if let track = statefulPlayer?.currentTrack() {
        let trackObj = track as AnyObject
        writeDebugLog("[Probe] currentTrack class = \(NSStringFromClass(type(of: trackObj)))")
        dumpMethods(of: type(of: trackObj), label: "SPTPlayerTrack")
    }

    // 3) 歌词滚动相关对象（歌词同步必然用到位置）
    if let scrollVC = nowPlayingScrollViewController {
        writeDebugLog("[Probe] scrollVC class = \(NSStringFromClass(type(of: scrollVC as AnyObject)))")
        dumpMethods(of: type(of: scrollVC as AnyObject), label: "scrollVC")

        let vm = Ivars<NSObject>(scrollVC).scrollViewModel
        writeDebugLog("[Probe] scrollViewModel class = \(NSStringFromClass(type(of: vm)))")
        dumpMethods(of: type(of: vm), label: "scrollViewModel")
    }
    if let npv = npvScrollViewController {
        writeDebugLog("[Probe] npvVC class = \(NSStringFromClass(type(of: npv as AnyObject)))")
        dumpMethods(of: type(of: npv as AnyObject), label: "npvVC")
    }
    if let ds = scrollDataSource {
        writeDebugLog("[Probe] scrollDataSource class = \(NSStringFromClass(type(of: ds as AnyObject)))")
        dumpMethods(of: type(of: ds as AnyObject), label: "scrollDataSource")
    }

    // 4) 玩家对象上 getter 候选的 responds（显式打日志）
    for sel in ["trackPosition", "playbackControls", "playerValue", "stateHandler",
                "position", "currentPosition", "playbackState", "currentTrackTime"] {
        writeDebugLog("[Probe] player responds \(sel) = \(player.responds(to: Selector(sel)))")
    }
}

private func dumpMethods(of cls: AnyClass, label: String) {
    var current: AnyClass? = cls
    var depth = 0
    while let c = current, depth < 8 {
        var count: UInt32 = 0
        if let methods = class_copyMethodList(c, &count) {
            for i in 0..<Int(count) {
                let m = methods[i]
                let name = NSStringFromSelector(method_getName(m))
                if matchesKeyword(name) {
                    let type = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
                    writeDebugLog("[Dump] \(label)#\(depth) \(name) || \(type)")
                }
            }
            free(methods)
        }
        current = class_getSuperclass(c)
        depth += 1
    }
}

private func matchesKeyword(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower.contains("position") || lower.contains("seek") || lower.contains("playback")
        || lower.contains("time") || lower.contains("progress") || lower.contains("duration")
        || lower.contains("state") || lower.contains("elapsed") || lower.contains("clock")
}
