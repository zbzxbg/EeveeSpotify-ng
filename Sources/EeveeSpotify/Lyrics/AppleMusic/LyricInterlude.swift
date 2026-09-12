import Foundation

// 移植自 MeloX `MeloX/Core/Lyrics/LyricInterludeTimeline.swift` 的模型部分（GPL-3.0）。
//
// 只移植了模型与呈现位置结构；`LyricInterludeTimeline` 的检测逻辑（间隙阈值、
// contentEndTime 估算、policy 过滤）等接入间奏功能时再补——现在先把渲染链路跑通，
// 避免一次性搬入没人调用的死代码。

enum LyricInterludeTimingSource: Hashable, Sendable {
    /// YRC 提供了作者标注的行/音节结束时间。
    case precise

    /// LRC 只有行起始时间，人声尾部是估算的。
    case lineSynchronized
}

enum LyricInterludeDetectionPolicy: Hashable, Sendable {
    /// 对齐 Apple Music 的作者时间轴路径，忽略推断出来的 LRC 间隙。
    case preciseTiming

    /// 把推断静音时长达到阈值的 LRC 间隙也算进来。
    case automatic(minimumInferredGapDuration: TimeInterval)
}

struct LyricInterlude: Identifiable, Hashable {
    let startTime: TimeInterval
    let countdownEndTime: TimeInterval
    let precedingLyricID: LyricLine.ID?
    let followingLyricID: LyricLine.ID
    let displayBeforeLyricID: LyricLine.ID
    let timingSource: LyricInterludeTimingSource

    var id: String {
        "lyric-interlude-\(startTime)-\(displayBeforeLyricID)-\(followingLyricID)"
    }

    var isPrelude: Bool {
        precedingLyricID == nil
    }

    /// 圆点在下一句歌词开始前就进入退出动画。
    var cueOutTime: TimeInterval {
        max(
            startTime,
            countdownEndTime
                - AppleMusicInterludeMotionProfile.iOS26_6.cueOutLeadTime
        )
    }

    var gapDuration: TimeInterval {
        max(countdownEndTime - startTime, 0)
    }
}

struct LyricInterludePlaybackPosition: Equatable {
    /// 常驻的 40pt 行拥有指示器生命周期；在歌词边界附近它可能已经视觉清空。
    let visibleInterludeID: LyricInterlude.ID?

    /// 在 cue-out 动画视觉完成前，槽位保持焦点。
    let focusedInterludeID: LyricInterlude.ID?

    /// 圆点消失之后、歌词作者标注的开始时间之前被提升的那一行。
    let promotedLyricID: LyricLine.ID?

    let nextTransitionTime: TimeInterval?
}
