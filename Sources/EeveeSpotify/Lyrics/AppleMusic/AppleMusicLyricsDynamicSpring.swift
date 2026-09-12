import Foundation

// 移植自 MeloX `MeloX/Core/Lyrics/AppleMusicLyricsDynamicSpring.swift`（GPL-3.0）。

/// 依赖时长的弹簧参数重建（观察自 Apple Music 的歌词行切换求解器）。
/// 短过渡用更硬的弹簧、长过渡用更软的，避免「快速切行时晃、慢速切行时僵」。
enum AppleMusicLyricsDynamicSpring {
    private static let minimumSourceDuration: TimeInterval = 0.20
    private static let maximumSourceDuration: TimeInterval = 0.75
    private static let sourceDurationRange: TimeInterval = 0.55
    private static let maximumDampingRatio = 0.90
    private static let dampingRatioRange = 0.12
    private static let minimumPeriod: TimeInterval = 0.48
    private static let periodRange: TimeInterval = 0.27

    static func parameters(
        sourceDuration: TimeInterval
    ) -> LyricPhysicalSpringParameters {
        let cappedSourceDuration: TimeInterval
        if sourceDuration.isNaN {
            cappedSourceDuration = minimumSourceDuration
        } else {
            cappedSourceDuration = min(
                sourceDuration,
                maximumSourceDuration
            )
        }
        let progress = clampedUnitValue(
            (cappedSourceDuration - minimumSourceDuration)
                / sourceDurationRange
        )
        let dampingRatio = maximumDampingRatio
            - progress * dampingRatioRange
        let period = progress * periodRange + minimumPeriod
        let mass = 1.0
        let angularFrequency = 2 * Double.pi / period
        let stiffness = angularFrequency * angularFrequency
        let damping = dampingRatio
            * 2
            * sqrt(mass * stiffness)
        return LyricPhysicalSpringParameters(
            mass: mass,
            stiffness: stiffness,
            damping: damping
        )
    }

    private static func clampedUnitValue(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(max(value, 0), 1)
    }
}
