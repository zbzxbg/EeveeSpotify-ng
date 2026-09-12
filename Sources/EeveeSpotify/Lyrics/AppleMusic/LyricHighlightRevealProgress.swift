import Foundation

// 移植自 MeloX `MeloX/Features/Player/Lyrics/Shared/LyricHighlightRevealProgress.swift`（GPL-3.0）。
//
// 这是「渐变填充前沿」的算法核心：把播放时间映射成 0~1 的高亮推进量。
// 它决定了 Apple Music 那种「液体填充」的观感，而不是开关式的逐词变色。

/// 把播放时间映射成歌词高亮的推进前沿。
///
/// 普通字形按自身时间轴连续推进。长音字形会**先快速揭示大部分**、在尾缘附近
/// 继续缓慢漂移，再在下一个字形到来前收尾——这样避免一个慢音节在大部分时间里
/// 看起来被劈成两半或卡住不动。
@available(iOS 26.0, *)
enum LyricHighlightRevealProgress {
    static func progress(
        playbackTime: TimeInterval,
        timing: LyricTimingTextAttribute,
        detectionMode: LyricsLongSyllableDetectionMode,
        durationThreshold: TimeInterval,
        lineFinishProgressAnimationDuration: TimeInterval? = nil
    ) -> Double {
        let finishDuration = resolvedFinishDuration(
            lineFinishProgressAnimationDuration
        )
        let duration = timing.endTime - timing.startTime
        let rawProgress = playedProgress(
            playbackTime: playbackTime,
            timing: timing,
            duration: duration
        )
        let regularProgress = smootherStep(rawProgress)
        guard duration > Metrics.attackDuration + finishDuration else {
            return regularProgress
        }

        guard LyricLongToneEmphasis.isLongTone(
            timing: timing,
            detectionMode: detectionMode,
            durationThreshold: durationThreshold
        ) else {
            return regularProgress
        }

        let elapsed = max(playbackTime - timing.startTime, 0)
        let attackProgress = smootherStep(elapsed / Metrics.attackDuration)
        let releaseStartTime = timing.endTime - finishDuration
        let releaseProgress = smootherStep(
            (playbackTime - releaseStartTime) / finishDuration
        )
        return unitProgress(
            Metrics.attackContribution * attackProgress
                + Metrics.continuousContribution * rawProgress
                + Metrics.releaseContribution * releaseProgress
        )
    }

    private static func resolvedFinishDuration(
        _ duration: TimeInterval?
    ) -> TimeInterval {
        guard let duration, duration.isFinite, duration > 0 else {
            return Metrics.releaseDuration
        }
        return duration
    }

    private static func playedProgress(
        playbackTime: TimeInterval,
        timing: LyricTimingTextAttribute,
        duration: TimeInterval
    ) -> Double {
        guard playbackTime >= timing.startTime else { return 0 }
        guard playbackTime < timing.endTime else { return 1 }
        guard duration > 0 else { return 1 }
        return unitProgress(
            (playbackTime - timing.startTime) / duration
        )
    }

    private static func smootherStep(_ value: Double) -> Double {
        let progress = unitProgress(value)
        return progress * progress * progress
            * (progress * (progress * 6 - 15) + 10)
    }

    private static func unitProgress(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

@available(iOS 26.0, *)
private extension LyricHighlightRevealProgress {
    enum Metrics {
        static let attackDuration: TimeInterval = 0.3
        static let releaseDuration: TimeInterval = 0.16
        static let attackContribution = 0.82
        static let continuousContribution = 0.08
        static let releaseContribution = 0.1
    }
}
