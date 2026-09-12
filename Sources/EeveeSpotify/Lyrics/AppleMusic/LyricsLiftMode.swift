import Foundation

// 移植自 MeloX `MeloX/Core/Settings/Lyrics/LyricsLiftMode.swift`（GPL-3.0）。
// 去掉 `L10n` 依赖（标题只用于设置界面，本项目暂不暴露该选项）。

/// 「上浮」动画的作用单位：整词还是单字。
enum LyricsLiftMode: String, CaseIterable, Identifiable, Sendable {
    case word
    case character

    var id: String { rawValue }
}
