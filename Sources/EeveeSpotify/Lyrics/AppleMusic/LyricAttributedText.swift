import SwiftUI

// 移植自 MeloX `MeloX/Features/Player/Lyrics/Shared/LyricAttributedText.swift`（GPL-3.0）。
//
// 属性名从 "MeloX.lyricTiming" / "MeloX.lyricPlacement" 改为 "EeveeSpotify.*"，
// 避免与其它 tweak 冲突；其余保持原样（含 iOS 26 的 AttributedTextFormattingDefinition 分支）。

/// 把运行期的歌词字形保存在**一个** attributed string 里。
/// 逐字 `Text` 插值会把本地化工作嵌进每个字符里，长行会拖死布局。
@available(iOS 18.0, *)
struct LyricAttributedText {
    private var content: AttributedString

    init(verbatim source: String) {
        content = AttributedString(source)
    }

    init(_ content: AttributedString) {
        self.content = content
    }

    var attributedString: AttributedString {
        content
    }

    var text: Text {
        Text(content)
    }
}

@available(iOS 18.0, *)
nonisolated enum LyricTimingAttributeKey: AttributedStringKey {
    public typealias Value = LyricTimingTextAttribute
    public static let name = "EeveeSpotify.lyricTiming"
}

@available(iOS 18.0, *)
nonisolated enum LyricPlacementAttributeKey: AttributedStringKey {
    public typealias Value = LyricRubyPlacementTextAttribute
    public static let name = "EeveeSpotify.lyricPlacement"
}

@available(iOS 18.0, *)
nonisolated struct LyricAttributeScope: AttributeScope {
    let timing: LyricTimingAttributeKey
    let placement: LyricPlacementAttributeKey
    let swiftUI: AttributeScopes.SwiftUIAttributes
}

@available(iOS 26.0, *)
private struct LyricTextFormatting: AttributedTextFormattingDefinition {
    var body: some AttributedTextFormattingDefinition<LyricAttributeScope> {}
}

@available(iOS 18.0, *)
extension View {
    /// 把自定义属性作用域注册给 SwiftUI 的文本布局引擎。
    /// 缺了这一步，`Text.Layout.Run` 上取不到 `LyricTimingTextAttribute`，填充前沿就无从计算。
    @ViewBuilder
    func lyricTextAttributes() -> some View {
        if #available(iOS 26, *) {
            attributedTextFormattingDefinition(LyricTextFormatting())
        } else {
            self
        }
    }
}
