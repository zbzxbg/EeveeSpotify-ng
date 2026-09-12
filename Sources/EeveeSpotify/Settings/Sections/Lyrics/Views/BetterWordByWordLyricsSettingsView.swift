import SwiftUI

/// 「更好的逐词歌词」的二级设置页。
///
/// 它挂在「开启逐词歌词」下面的二级菜单里，而不是主列表的平级开关 ——
/// 这项功能只在逐词歌词开启后才有意义。
///
/// ⚠️ 背景相关的两个功能（模糊封面 / 系统材质）**故意没有开关**：
/// 只要本项开启，它们就跟着启用（见 `NgzhwmSettingsViewModel` 里那两个
/// 派生属性）。开关多了反而让用户不知道该开哪个。
struct BetterWordByWordLyricsSettingsView: View {

    @ObservedObject var viewModel: EeveeLyricsSettingsViewModel

    var body: some View {
        List {
            Section(
                footer: Text("ngzhwm_better_word_by_word_lyrics_description".localized)
            ) {
                Toggle(
                    "ngzhwm_better_word_by_word_lyrics".localized,
                    isOn: $viewModel.betterWordByWordLyrics
                )
            }

            // 固定说明：把"这一项会自动带上什么"讲清楚，
            // 免得用户去找已经不存在的背景开关。
            Section {
                labeledRow(
                    "ngzhwm_better_lyrics_includes_backdrop".localized,
                    systemImage: "photo.fill"
                )
                labeledRow(
                    "ngzhwm_better_lyrics_includes_material".localized,
                    systemImage: "square.stack.3d.up.fill"
                )
                labeledRow(
                    "ngzhwm_better_lyrics_hides_translation".localized,
                    systemImage: "character.bubble.fill"
                )
            } header: {
                Text("ngzhwm_better_lyrics_includes_header".localized)
            }

            NonIPadSpacerView()
        }
        .listStyle(GroupedListStyle())
    }

    private func labeledRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}
