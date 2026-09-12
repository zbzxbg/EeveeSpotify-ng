import SwiftUI

// 移植自 MeloX `MeloX/Features/Player/Lyrics/Shared/LyricGlowTextRenderer.swift`
// 的头部类型定义部分（GPL-3.0）。
//
// 拆成独立文件是因为这些类型被渲染器、视觉强调、ruby 排版、文本构建器共同引用。
//
// ⚠️ 整个文件标注 iOS 26+：`TextAttribute` 协议本身 iOS 18 就有，
// 但让它在 `Text.Layout.Run` 上被读到，依赖 iOS 26 的
// `attributedTextFormattingDefinition(_:)` 注册（见 `LyricAttributedText.swift`）。
// 统一按 26 标注，避免"编译能过、运行时静默取不到值"这种最难查的状态。

/// 挂在每个**字**上的时间轴信息。渲染器通过它取到这个字的起止时间、
/// 所属音节/词的范围，从而算出填充前沿与长音强调。
@available(iOS 26.0, *)
struct LyricTimingTextAttribute: TextAttribute, Hashable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let syllableStartTime: TimeInterval
    let syllableEndTime: TimeInterval
    let characterIndex: Int
    let characterCount: Int
    let wordStartTime: TimeInterval
    let wordEndTime: TimeInterval
    let wordCharacterIndex: Int
    let wordCharacterCount: Int
    let usesWordTimingForLongTone: Bool
    let isWhitespace: Bool
}

/// 歌词行获得焦点过程中使用的**绝对** alpha 端点。
///
/// Apple Music 让同一行内「已唱」与「未唱」字形跟随换行弹簧一起动。未唱渲染器
/// 位于整行外层 opacity 之内，所以它必须**补偿**父层 alpha，而不是再叠一层独立淡出。
struct LyricFocusOpacityEndpoints: Equatable, Sendable {
    let deselected: Double
    let selected: Double
    let selectedUpcoming: Double

    func relativeUpcomingOpacity(at progress: Double) -> Double {
        let progress = Self.unitProgress(progress)
        let outerOpacity = Self.interpolate(
            from: deselected,
            to: selected,
            progress: progress
        )
        let absoluteUpcomingOpacity = Self.interpolate(
            from: deselected,
            to: selectedUpcoming,
            progress: progress
        )
        guard outerOpacity > 0 else { return 0 }
        return Self.unitProgress(absoluteUpcomingOpacity / outerOpacity)
    }

    private static func interpolate(
        from start: Double,
        to end: Double,
        progress: Double
    ) -> Double {
        start + (end - start) * progress
    }

    private static func unitProgress(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// ruby（音译）排版用的水平偏移。MeloX 不往字符串里插占位空白，
/// 而是在绘制时按字符平移，避免改变文本本身的换行行为。
@available(iOS 26.0, *)
struct LyricRubyPlacementTextAttribute: TextAttribute, Hashable, Sendable {
    let horizontalOffset: CGFloat
}
