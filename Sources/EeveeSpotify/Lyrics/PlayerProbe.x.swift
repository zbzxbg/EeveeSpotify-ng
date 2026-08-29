import Orion
import UIKit

// ⚠️ 临时探针（确认签名后删除本文件）：
// 验证 StatefulPlayer 的进度/seek 方法签名。二进制扫描线索：
//   playbackPosition → Td（double）；elapsedTimeMs → TQ（uint64）
//   seekToTimeInterval:（double 秒）；trackPosition / playbackControls → 对象 getter
//   seekToPosition → Td,R（readonly double，疑似 scrub 目标位置）

private var playerProbeHasRun = false

@objc protocol ProbePlayerPlaybackPositionDouble { func playbackPosition() -> Double }
@objc protocol ProbePlayerPlaybackPositionInt64 { func playbackPosition() -> Int64 }
@objc protocol ProbePlayerCurrentPlaybackTimeDouble { func currentPlaybackTime() -> Double }
@objc protocol ProbePlayerCurrentPlaybackTimeInt64 { func currentPlaybackTime() -> Int64 }
@objc protocol ProbePlayerElapsedTimeMsInt64 { func elapsedTimeMs() -> Int64 }
@objc protocol ProbePlayerTrackPositionGetter { func trackPosition() -> NSObject? }
@objc protocol ProbePlayerPlaybackControlsGetter { func playbackControls() -> NSObject? }
@objc protocol ProbePlayerPlayerValueGetter { func playerValue() -> NSObject? }
@objc protocol ProbePlayerStateHandlerGetter { func stateHandler() -> NSObject? }

func runPlayerProbe() {
    guard !playerProbeHasRun else { return }

    guard let player = statefulPlayer as? NSObject else {
        writeDebugLog("[Probe] statefulPlayer nil — retry next track")
        return
    }
    playerProbeHasRun = true

    writeDebugLog("[Probe] statefulPlayer class = \(NSStringFromClass(type(of: player)))")
    probeSelectors(player, label: "player")
    probePositionValues(player, label: "player")

    if player.responds(to: Selector("trackPosition")) {
        if let tp = Dynamic.convert(player, to: ProbePlayerTrackPositionGetter.self).trackPosition() {
            writeDebugLog("[Probe] trackPosition class = \(NSStringFromClass(type(of: tp)))")
            probeSelectors(tp, label: "trackPosition")
            probePositionValues(tp, label: "trackPosition")
        } else {
            writeDebugLog("[Probe] trackPosition -> nil")
        }
    }

    if player.responds(to: Selector("playbackControls")) {
        if let c = Dynamic.convert(player, to: ProbePlayerPlaybackControlsGetter.self).playbackControls() {
            writeDebugLog("[Probe] playbackControls class = \(NSStringFromClass(type(of: c)))")
            probeSelectors(c, label: "playbackControls")
        } else {
            writeDebugLog("[Probe] playbackControls -> nil")
        }
    }

    if player.responds(to: Selector("playerValue")) {
        if let v = Dynamic.convert(player, to: ProbePlayerPlayerValueGetter.self).playerValue() {
            writeDebugLog("[Probe] playerValue class = \(NSStringFromClass(type(of: v)))")
            probeSelectors(v, label: "playerValue")
            probePositionValues(v, label: "playerValue")
        } else {
            writeDebugLog("[Probe] playerValue -> nil")
        }
    }

    if player.responds(to: Selector("stateHandler")) {
        if let h = Dynamic.convert(player, to: ProbePlayerStateHandlerGetter.self).stateHandler() {
            writeDebugLog("[Probe] stateHandler class = \(NSStringFromClass(type(of: h)))")
            probeSelectors(h, label: "stateHandler")
        } else {
            writeDebugLog("[Probe] stateHandler -> nil")
        }
    }
}

/// 只查 responds，不调用带参方法（避免误触发 seek）。
private func probeSelectors(_ obj: NSObject, label: String) {
    let selectors = [
        "playbackPosition", "currentPlaybackTime", "currentTrackPosition",
        "currentTrackTimeSecs", "elapsedTimeMs", "seekToPosition",
        "seekToTimeInterval:", "seekTo:", "seekToPosition:", "setPlaybackPosition:",
    ]
    for sel in selectors {
        writeDebugLog("[Probe] \(label) responds \(sel) = \(obj.responds(to: Selector(sel)))")
    }
}

/// 值型 getter：分别按 double / Int64 读取，看哪个读出来是合理值（判断真实类型与单位）。
private func probePositionValues(_ obj: NSObject, label: String) {
    if obj.responds(to: Selector("playbackPosition")) {
        let d = Dynamic.convert(obj, to: ProbePlayerPlaybackPositionDouble.self).playbackPosition()
        let i = Dynamic.convert(obj, to: ProbePlayerPlaybackPositionInt64.self).playbackPosition()
        writeDebugLog("[Probe] \(label).playbackPosition as Double = \(d); as Int64 = \(i)")
    }
    if obj.responds(to: Selector("currentPlaybackTime")) {
        let d = Dynamic.convert(obj, to: ProbePlayerCurrentPlaybackTimeDouble.self).currentPlaybackTime()
        let i = Dynamic.convert(obj, to: ProbePlayerCurrentPlaybackTimeInt64.self).currentPlaybackTime()
        writeDebugLog("[Probe] \(label).currentPlaybackTime as Double = \(d); as Int64 = \(i)")
    }
    if obj.responds(to: Selector("elapsedTimeMs")) {
        let i = Dynamic.convert(obj, to: ProbePlayerElapsedTimeMsInt64.self).elapsedTimeMs()
        writeDebugLog("[Probe] \(label).elapsedTimeMs as Int64 = \(i)")
    }
}
