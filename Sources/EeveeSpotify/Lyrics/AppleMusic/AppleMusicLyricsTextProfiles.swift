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
///
/// 注意这里是 `struct` 而不是 `enum`：它带存储属性、用成员逐一初始化器构造，
/// 写成 `enum` 会同时报"存储属性不允许"和"没有 Self(...) 初始化器"两个错。
struct LyricsTypographyScale {

    /// 主歌词字号
    let primaryFontSize: CGFloat
    /// 译文/罗马音字号
    let supplementalFontSize: CGFloat
    /// 视觉行之间的间距
    let lineSpacing: CGFloat
    /// 同一行的原文与译文之间
    let supplementalSpacing: CGFloat

    /// 全屏歌词页。
    ///
    /// ⚠️ 字号是**被容器宽度约束的**，不能凭观感调大。
    /// 实测（`[LyricWrap] text=` 字段，26pt / 366pt 容器）：
    ///   "I'm tryna put you in the worst mood ah"  → 479.4pt
    ///   "Twenty racks a table cut from ebony"     → 455.6pt
    /// 也就是 **26pt 下每字符约 12.6pt**，38 字符的行要 479pt —— 远超 366pt 容器，
    /// 于是**几乎每一行都必然折成两行**，且第一行剩不下多少空间。
    /// 这不是折行算法的问题，是字号超出容器容量。
    ///
    /// 22pt 时该行约 406pt，第一行能放到约 34 字符（26pt 只有 31）。
    /// 选 22 还有一个理由：它与本项目原有 overlay（`LyricsWordByWord.x.swift`
    /// 的 `lyricsFontSize = 22`）一致，是用户已经接受过的量级。
    static let fullscreen = Self(
        primaryFontSize: 22,
        supplementalFontSize: 16,
        lineSpacing: 15,
        supplementalSpacing: 4
    )

    /// 内嵌「预览歌词」卡片：容器约 200pt 高、且更窄，比全屏再小一档。
    ///
    /// 20pt 时实测 "Twenty racks a table cut from ebony" ≈ 339pt，
    /// 能塞进预览的 342pt 容器（不折行）。再大就开始折。
    static let preview = Self(
        primaryFontSize: 20,
        supplementalFontSize: 14,
        lineSpacing: 10,
        supplementalSpacing: 3
    )

    /// 按系数派生一档，用于副唱（背景人声）这种"同一行里更小的一层"。
    ///
    /// 行距**不缩放**：它是绝对值（pt），跟着字号等比缩会算出 4~5pt 这种
    /// 明显过小的值；小字号本身不需要那么大的行距，沿用父级即可。
    func scaled(
        primaryBy primaryFactor: Double,
        supplementalBy supplementalFactor: Double
    ) -> Self {
        Self(
            primaryFontSize: primaryFontSize * CGFloat(primaryFactor),
            supplementalFontSize: supplementalFontSize * CGFloat(supplementalFactor),
            lineSpacing: lineSpacing,
            supplementalSpacing: supplementalSpacing
        )
    }
}
