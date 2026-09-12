import Foundation

// 移植自 MeloX（GPL-3.0），对应文件：
//   MeloX/Core/Lyrics/AppleMusicLyricsTypographyProfile.swift
//   MeloX/Core/Lyrics/AppleMusicLyricsSupplementalTextProfile.swift
//
// 合并到本文件是为了减少文件数量；两组常量互不相关，分别对应「主歌词排版」与
// 「译文/音译排版」。

// MARK: - 主歌词排版

/// Apple Music 主歌词的字号。
///
/// MeloX 说明：Music 26.6 的 UIKit 规格里存的是 48pt 源字号，但它的文本容器几何
/// 与「直接给 `SynchronizedLyricText` 设 48pt」并不等价，实际渲染基线更接近
/// `.largeTitle`，所以这里取 36pt。
nonisolated struct AppleMusicLyricsTypographyProfile: Equatable, Sendable {
    let primaryFontSize: Double

    static let iOS26_6 = Self(
        primaryFontSize: 36
    )
}

// MARK: - 译文 / 音译排版

/// Apple Music 音译层与译文层的排版常量（iOS 26.6 实现，非公开 API）。
nonisolated struct AppleMusicLyricsSupplementalTextProfile: Equatable, Sendable {
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
