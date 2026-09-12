import CoreGraphics
import Foundation

// 移植自 MeloX `MeloX/Core/Lyrics/AppleMusicInterludeMotionProfile.swift`（GPL-3.0）。

/// 间奏「呼吸点」的几何与时间参数（观察自 Apple Music 26.6 的
/// `InstrumentalContentLayer` / `LyricsSpecs`）。
struct AppleMusicInterludeMotionProfile: Hashable, Sendable {
    static let iOS26_6 = AppleMusicInterludeMotionProfile(
        dotCount: 3,
        dotLength: 12,
        dotMargin: 8,
        viewHeight: 40,
        fillLeadInDuration: 1,
        fillAnimationDuration: 0.8,
        fillStagger: 0.06,
        inactiveDotOpacity: 0.1,
        cueOutLeadTime: 1.8,
        cuePeakScale: 1.2,
        cuePeakDuration: 1,
        cueFadeDuration: 0.3,
        cueTerminalScale: 0.2,
        cueTerminalScaleDuration: 0.5,
        breathLowerScale: 0.9,
        breathUpperScale: 1.2,
        breathDelay: 0.2,
        breathAnimationInset: 0.4
    )

    let dotCount: Int
    let dotLength: CGFloat
    let dotMargin: CGFloat
    let viewHeight: CGFloat
    let fillLeadInDuration: TimeInterval
    let fillAnimationDuration: TimeInterval
    let fillStagger: TimeInterval
    let inactiveDotOpacity: Double
    let cueOutLeadTime: TimeInterval
    let cuePeakScale: CGFloat
    let cuePeakDuration: TimeInterval
    let cueFadeDuration: TimeInterval
    let cueTerminalScale: CGFloat
    let cueTerminalScaleDuration: TimeInterval
    let breathLowerScale: CGFloat
    let breathUpperScale: CGFloat
    let breathDelay: TimeInterval
    let breathAnimationInset: TimeInterval

    var contentWidth: CGFloat {
        CGFloat(dotCount) * dotLength
            + CGFloat(max(dotCount - 1, 0)) * dotMargin
    }

    /// 退出动画在下一个歌词时间戳之前就视觉结束（淡出 1.3s、缩放塌缩 1.5s 取较大者）。
    var visualExitDuration: TimeInterval {
        max(
            cuePeakDuration + cueFadeDuration,
            cuePeakDuration + cueTerminalScaleDuration
        )
    }

    /// 外侧两点刻意用越界锚点：展开到 1.2x、收缩到 0.2x。
    func dotAnchorX(at index: Int) -> CGFloat {
        switch index {
        case 0:
            return 1.8
        case dotCount - 1:
            return -0.8
        default:
            return 0.5
        }
    }

    func timing(
        for interlude: LyricInterlude
    ) -> AppleMusicInterludeMotionTiming {
        let startTime = interlude.startTime
        let endTime = max(interlude.countdownEndTime, startTime)
        let cueOutTime = max(startTime, endTime - cueOutLeadTime)
        let visualEndTime = min(
            endTime,
            cueOutTime + visualExitDuration
        )
        let activeDuration = max(cueOutTime - startTime, 0)
        let breathCount = max(floor(activeDuration * 0.25), 1)
        let breathHalfCycleDuration = activeDuration
            / breathCount
            * 0.5
        let fillStartTime = startTime + fillLeadInDuration
        let fillDuration = max(cueOutTime - fillStartTime, 0)
        let fillStageInterval = fillDuration / Double(dotCount)

        return AppleMusicInterludeMotionTiming(
            startTime: startTime,
            endTime: endTime,
            visualEndTime: visualEndTime,
            cueOutTime: cueOutTime,
            fillStartTime: fillStartTime,
            fillStageInterval: fillStageInterval,
            breathHalfCycleDuration: breathHalfCycleDuration
        )
    }
}

struct AppleMusicInterludeMotionTiming: Hashable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let visualEndTime: TimeInterval
    let cueOutTime: TimeInterval
    let fillStartTime: TimeInterval
    let fillStageInterval: TimeInterval
    let breathHalfCycleDuration: TimeInterval
}
