import Foundation

// 移植自 MeloX（GPL-3.0）：
//   MeloX/Core/Lyrics/AppleMusicLyricsTypographyProfile.swift
//   MeloX/Core/Lyrics/AppleMusicLyricsSupplementalTextProfile.swift
// 另加本项目自己的分档（见下）。
//
// ⚠️ 关键改动的理由（重要，别改回去）：
// MeloX 的 36pt / 段间距 39 / 行距 25 是为**整屏深色画布**调出来的 ——
// 一屏只显示约 5 行、且整页都是歌词。本项目有两个比它小得多的容器
// （全屏歌词页约 700pt 高、内嵌预览约 200pt 高），照搬 36pt 的结果是：
//   · 英文长句被拆成 3 行，"字太大了"
//   · 预览卡片里 3 行字就占满整个卡片
// 所以这里以**本项目原有 overlay 的排版**（22pt 主 / 16pt 译文 / 行距 18）
// 作为基准档，Apple Music 的 36pt 那一档只在将来做"整屏独立页"时才可能用到。

// MARK: - 主歌词字号的「仿 Apple Music 原值」（保留备查）

/// Apple Music 主歌词的字号。
///
/// MeloX 说明：Music 26.6 的 UIKit 规格里存的是 48pt 源字号，但它的文本容器几何
/// 与「直接给 `SynchronizedLyricText` 设 48pt」并不等价，实际渲染基线更接近
/// `.largeTitle`，所以取 36pt。
///
/// **本项目当前不使用这个值**（见文件头说明），保留它是为了注明出处、
/// 以及将来真要做"整屏接管"的全屏页时可以直接取用。
struct AppleMusicLyricsTypographyProfile: Equatable, Sendable {
    let primaryFontSize: Double

    static let iOS26_6 = Self(
        primaryFontSize: 36
    )
}

// MARK: - 译文 / 音译排版

/// Apple Music 音译层与译文层的排版常量（iOS 26.6 实现，非公开 API）。
struct AppleMusicLyricsSupplementalTextProfile: Equatable, Sendable {
    let transliterationSpacing: Double
    let transliterationMinimumWordSpacing: Double
    let translationSpacing: Double
    let translationBottomPadding: Double
    let hiddenVerticalOffset: Double

    static let iOS26_6 = Self(
        transliterationSpacing: 5,
        transliterationMinimumWordSpacing: 5,
        translationSpacing: 7,
        translationBottomPadding: 4,
        hiddenVerticalOffset: -20
    )
}

// MARK: - 本项目实际使用的分档

/// 按容器尺度分档的歌词排版。
///
/// 「仿 Apple Music」的部分是**运动**（填充前沿、长音强调、焦点弹簧、级联），
/// 排版则跟随本项目原有 overlay 的比例，这样它嵌在 Spotify 页面里不违和。
enum LyricsTypographyScale {

    /// 主歌词字号
    let primaryFontSize: CGFloat
    /// 译文/罗马音字号
    let supplementalFontSize: CGFloat
    /// 视觉行之间的间距
    let lineSpacing: CGFloat
    /// 同一行的原文与译文之间
    let supplementalSpacing: CGFloat

    /// 全屏歌词页：接近本项目原有 overlay（22pt），略放大以适应整屏。
    static let fullscreen = Self(
        primaryFontSize: 24,
        supplementalFontSize: 16,
        lineSpacing: 14,
        supplementalSpacing: 4
    )

    /// 内嵌「预览歌词」卡片：容器只有约 200pt 高，必须明显小于全屏。
    ///
    /// 17pt 是与 Spotify 原生预览歌词同量级的值 —— 预览卡片本来就该"像
    /// Spotify 自己的卡片"，而不是一张缩小的全屏歌词页。
    static let preview = Self(
        primaryFontSize: 17,
        supplementalFontSize: 13,
        lineSpacing: 8,
        supplementalSpacing: 3
    )
}
