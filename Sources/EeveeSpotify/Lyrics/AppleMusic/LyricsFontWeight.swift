import SwiftUI
import UIKit

// 移植自 MeloX `MeloX/Core/Settings/Lyrics/LyricsFontWeight.swift`（GPL-3.0）。
// 去掉 `L10n` 依赖（标题只用于设置界面）。

enum LyricsFontWeight: String, CaseIterable, Identifiable {
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy

    var id: String { rawValue }

    var title: String { rawValue }

    var swiftUIWeight: Font.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    var uiKitWeight: UIFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}
