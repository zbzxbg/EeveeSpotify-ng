import Foundation

// 移植自 MeloX `MeloX/Core/Lyrics/AppleMusicLyricsMotionProfile.swift`（GPL-3.0）。
//
// 这些常量是从 Apple Music 26.6 的歌词视图反推出来的（MeloX 作者的还原值），
// 不是公开 API。**它们是这套观感的核心**，改动前请先想清楚影响面。

/// Apple Music 歌词运动参数。
struct AppleMusicLyricsMotionProfile: Equatable, Sendable {
    let firstLineStartOffset: Double
    /// 同步模式下，焦点行顶部相对视口高度的百分比（减去字体 ascender 之前）。
    let selectedLineTopRelativePercent: Double
    /// 静态模式下的垂直内边距，不与同步模式叠加。
    let staticTopContentInset: Double
    let staticBottomContentInset: Double
    let paragraphSpacing: Double
    let lineSpacing: Double
    let backgroundVocalsTopSpacing: Double
    let backgroundVocalsDeselectedScale: Double
    let backgroundVocalsFontCoefficient: Double
    let translationBackgroundVocalsFontCoefficient: Double
    let transliterationBackgroundVocalsFontCoefficient: Double
    let cascadeDelay: TimeInterval
    let deselectedScale: Double
    let nonFocusedBlurRadius: Double
    let maximumNonFocusedBlurRadius: Double
    let selectedTextOpacity: Double
    let selectedUpcomingTextOpacity: Double
    let deselectedTextOpacity: Double
    let increasedContrastSelectedTextOpacity: Double
    let increasedContrastSelectedUpcomingTextOpacity: Double
    let increasedContrastDeselectedTextOpacity: Double
    /// 行焦点模糊动画同时驱动亮度滤镜。
    let focusBlurTransitionDuration: TimeInterval
    let focusBlurTransitionControlPoint1X: Double
    let focusBlurTransitionControlPoint1Y: Double
    let focusBlurTransitionControlPoint2X: Double
    let focusBlurTransitionControlPoint2Y: Double
    let animationHeadstart: TimeInterval
    /// 长音强调的缩放范围。**永远不要缩放整行**，只缩放定时字形。
    let emphasisScaleRange: ClosedRange<Double>
    let lineFinishProgressAnimationDuration: TimeInterval
    let lineProgressionGradientFeather: Double
    let glowRadius: Double
    let syllableLift: Double
    /// 默认焦点与换行求解器参数。
    let lineChangeSpring: LyricPhysicalSpringParameters
    /// 强制跳转 / 追赶路径上的求解器参数。
    let forcedLineCatchUpSpring: LyricPhysicalSpringParameters
    /// 译文/音译显示求解器参数。
    let supplementalTextShowSpring: LyricPhysicalSpringParameters
    /// 译文/音译移除求解器参数。
    let supplementalTextHideSpring: LyricPhysicalSpringParameters

    static let iOS26_6 = Self(
        firstLineStartOffset: 60,
        selectedLineTopRelativePercent: 12,
        staticTopContentInset: 22,
        staticBottomContentInset: 30,
        paragraphSpacing: 39,
        lineSpacing: 25,
        backgroundVocalsTopSpacing: 15,
        backgroundVocalsDeselectedScale: 0.9,
        backgroundVocalsFontCoefficient: 0.63,
        translationBackgroundVocalsFontCoefficient: 0.36,
        transliterationBackgroundVocalsFontCoefficient: 0.27,
        cascadeDelay: 0.05,
        deselectedScale: 0.98,
        nonFocusedBlurRadius: 3,
        maximumNonFocusedBlurRadius: 4,
        selectedTextOpacity: 1,
        selectedUpcomingTextOpacity: 0.35,
        deselectedTextOpacity: 0.175,
        increasedContrastSelectedTextOpacity: 1,
        increasedContrastSelectedUpcomingTextOpacity: 0.85,
        increasedContrastDeselectedTextOpacity: 0.4,
        focusBlurTransitionDuration: 0.12,
        focusBlurTransitionControlPoint1X: 0.33,
        focusBlurTransitionControlPoint1Y: 0,
        focusBlurTransitionControlPoint2X: 0.2,
        focusBlurTransitionControlPoint2Y: 0.1,
        animationHeadstart: 0.1,
        emphasisScaleRange: 1...1.14,
        lineFinishProgressAnimationDuration: 0.25,
        lineProgressionGradientFeather: 30,
        glowRadius: 5,
        syllableLift: 2,
        lineChangeSpring: LyricPhysicalSpringParameters(
            mass: 1,
            stiffness: 100,
            damping: 18
        ),
        forcedLineCatchUpSpring: LyricPhysicalSpringParameters(
            mass: 2,
            stiffness: 260,
            damping: 50
        ),
        supplementalTextShowSpring: LyricPhysicalSpringParameters(
            mass: 1,
            stiffness: 150,
            damping: 30
        ),
        supplementalTextHideSpring: LyricPhysicalSpringParameters(
            mass: 1,
            stiffness: 130,
            damping: 30
        )
    )

    func dynamicSpring(
        sourceDuration: TimeInterval
    ) -> LyricPhysicalSpringParameters {
        AppleMusicLyricsDynamicSpring.parameters(
            sourceDuration: sourceDuration
        )
    }
}
