import SwiftUI

// 移植自 MeloX `MeloX/Features/Player/Lyrics/Shared/LyricAttributedText.swift`（GPL-3.0）。
//
// 与 MeloX 原版的差异：
//   1. 去掉 `nonisolated`（本项目以 Swift 5 语言模式编译，该修饰符会报
//      "'nonisolated' modifier cannot be applied to this declaration"）。
//   2. 属性名前缀改为 "EeveeSpotify."，避免与其它 tweak 冲突。
//   3. 去掉了 macOS 15 的 `#unavailable` 回退分支（本项目只有 iOS）。
//
// ★ 这个文件是逐字填充能否生效的关键 ★
//
// `LyricTimingTextAttribute` 挂在每个字上，渲染器靠 `run[LyricTimingTextAttribute.self]`
// 读取它来算填充前沿。但 SwiftUI 的文本布局引擎**默认不认识自定义 TextAttribute** ——
// 必须通过 `attributedTextFormattingDefinition(_:)` 把 `LyricAttributeScope` 注册给它，
// 否则 `run[...]` 永远返回 nil，表现为：文字正常显示但**完全不亮、没有填充推进**，
// 而且编译器和运行期都不报任何错（静默忽略）。
//
// 该修饰符是 iOS 26 引入的 —— 这正是「Apple Music 歌词层最低要求 iOS 26」的**唯一**
// 真实技术原因。TextRenderer / Text.Layout / TextAttribute 本身 iOS 18 就有。

/// 把运行期的歌词字形保存在**一个** attributed string 里。
/// 逐字 `Text` 插值会把本地化工作嵌进每个字符里，长行会拖死布局。
@available(iOS 26.0, *)
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

@available(iOS 26.0, *)
enum LyricTimingAttributeKey: AttributedStringKey {
    typealias Value = LyricTimingTextAttribute
    static let name = "EeveeSpotify.lyricTiming"
}

@available(iOS 26.0, *)
enum LyricPlacementAttributeKey: AttributedStringKey {
    typealias Value = LyricRubyPlacementTextAttribute
    static let name = "EeveeSpotify.lyricPlacement"
}

@available(iOS 26.0, *)
struct LyricAttributeScope: AttributeScope {
    let timing: LyricTimingAttributeKey
    let placement: LyricPlacementAttributeKey
    let swiftUI: AttributeScopes.SwiftUIAttributes
}

/// 空的格式化定义 —— 它存在的意义不是「格式化」，而是**声明属性作用域**。
/// MeloX 原注释也说明了这点：`AttributeScope` 必须由某个
/// `AttributedTextFormattingDefinition` 承载，才能被 `attributedTextFormattingDefinition(_:)` 接受。
@available(iOS 26.0, *)
struct LyricTextFormatting: AttributedTextFormattingDefinition {
    var body: some AttributedTextFormattingDefinition<LyricAttributeScope> {}
}

@available(iOS 26.0, *)
extension View {
    /// 把自定义属性作用域注册给 SwiftUI 的文本布局引擎。
    /// **不加这一层，逐字时间轴就取不到值**（详见文件头注释）。
    func lyricTextAttributes() -> some View {
        attributedTextFormattingDefinition(LyricTextFormatting())
    }
}
