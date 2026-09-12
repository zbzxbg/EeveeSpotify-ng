import SwiftUI

// 移植自 MeloX `MeloX/Features/Player/Lyrics/Shared/LyricAttributedText.swift`（GPL-3.0）。
//
// 与 MeloX 原版的**有意差异**：
//   1. 删掉了 `AttributedTextFormattingDefinition` / `attributedTextFormattingDefinition`
//      那段（MeloX 用 `@available(iOS 26)` 包着，且它自己的注释说明那是个**空的定义、
//      只为满足 iOS 26 的 API 形状**）。本项目 CI 用 iOS 18 SDK，那个符号不存在；
//      删掉不影响自定义属性在 `Text.Layout.Run` 上的读取。
//   2. 去掉 `nonisolated`（本项目以 Swift 5 语言模式编译，该修饰符会报
//      "'nonisolated' modifier cannot be applied to this declaration"）。
//   3. 属性名前缀改为 "EeveeSpotify."，避免与其它 tweak 冲突。

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
enum LyricTimingAttributeKey: AttributedStringKey {
    typealias Value = LyricTimingTextAttribute
    static let name = "EeveeSpotify.lyricTiming"
}

@available(iOS 18.0, *)
enum LyricPlacementAttributeKey: AttributedStringKey {
    typealias Value = LyricRubyPlacementTextAttribute
    static let name = "EeveeSpotify.lyricPlacement"
}

@available(iOS 18.0, *)
struct LyricAttributeScope: AttributeScope {
    let timing: LyricTimingAttributeKey
    let placement: LyricPlacementAttributeKey
    let swiftUI: AttributeScopes.SwiftUIAttributes
}
