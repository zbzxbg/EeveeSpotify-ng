import SwiftUI

struct NgzhwmTranslateSettingsView: View {

    @AppStorage("ngzhwm_chineseRomanization") var chineseRomanization: Bool = false
    @AppStorage("ngzhwm_japaneseRomanization") var japaneseRomanization: Bool = false
    @AppStorage("ngzhwm_koreanRomanization") var koreanRomanization: Bool = false
    
    var body: some View {
        List {
            // 一个 Section 包含三个 Toggle，它们会紧挨在一起
            Section(
                footer: Text("单独设置每种语言的歌词是否罗马化，该选项生效需要开启whoeevee菜单内的“罗马化歌词”。若有未开启的选项，歌词会直接返回而不经过罗马化。")
            ) {
                Toggle("中文歌词罗马化", isOn: $chineseRomanization)
                Toggle("日语歌词罗马化", isOn: $japaneseRomanization)
                Toggle("韩语歌词罗马化", isOn: $koreanRomanization)
            }
        }
        .listStyle(GroupedListStyle())
    }
}