import SwiftUI

// 移植自 MeloX `MeloX/Features/Player/Lyrics/Shared/LyricLineFitting.swift`（GPL-3.0）。

/// 单行超宽时的缩放修正：让过长的行缩到可用宽度内，而不是溢出被裁掉。
///
/// 标注 iOS 18 而不是技术上够用的 17：唯一调用方是同样 18+ 的
/// `LyricGlowTextRenderer`，统一门槛可以少一层嵌套判断。
@available(iOS 26.0, *)
enum LyricLineFitting {
    static func validWidth(_ width: CGFloat?) -> CGFloat? {
        guard let width, width.isFinite, width > 0 else {
            return nil
        }
        return width
    }

    static func drawingTransform(
        for line: Text.Layout.Line,
        constrainedWidth: CGFloat?,
        centersLine: Bool,
        trailingSafety: CGFloat
    ) -> CGAffineTransform? {
        guard let width = validWidth(constrainedWidth) else {
            return nil
        }

        let bounds = line.typographicBounds.rect
        guard bounds.width.isFinite,
              bounds.width > 0,
              bounds.minX.isFinite,
              bounds.midY.isFinite else {
            return nil
        }

        let availableWidth = max(
            width - max(trailingSafety, 0),
            1
        )
        let scale = min(
            max(availableWidth / bounds.width, 0),
            1
        )
        let translationX: CGFloat
        if centersLine {
            // SwiftUI 已经把居中行摆好了。再按渲染器宽度居中一次会把对齐
            // 应用两遍、整行右移。这里保留原生中心，只在过宽时围绕它缩放。
            guard scale < 1 else { return nil }
            translationX = bounds.midX * (1 - scale)
        } else {
            translationX = -bounds.minX * scale
        }
        let translationY = bounds.midY * (1 - scale)

        guard scale < 1
                || abs(translationX) > 0.001
                || abs(translationY) > 0.001 else {
            return nil
        }
        return CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: translationX,
            ty: translationY
        )
    }
}
