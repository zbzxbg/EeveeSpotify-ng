import SwiftUI

struct NgzhwmContainerSettingsView: View {
    @State private var multiLevelFallback: Bool = UserDefaults.standard.bool(forKey: "ngzhwm_multiLevelLyricsFallback")
    
    @AppStorage("ngzhwm_chineseRomanization") var chineseRomanization: Bool = false
    @AppStorage("ngzhwm_japaneseRomanization") var japaneseRomanization: Bool = false
    @AppStorage("ngzhwm_koreanRomanization") var koreanRomanization: Bool = false
    
    var body: some View {
        List {
            Section(
                footer: Text("当此选项开启时，歌词将按照Mxm-PL-LRC-Gen的方式多级回退查询展示（每个源最长尝试两秒，若两秒还未返回内容则查询下一个源）。当此选项关闭时，歌词会按照whoeevee菜单内用户的设置进行查询展示。")
            ) {
                Toggle(
                    "歌词多级回退",
                    isOn: $multiLevelFallback
                )
            }
            
            Section(
                footer: Text("单独设置每种语言的歌词是否罗马化，该选项生效需要开启whoeevee菜单内的“罗马化歌词”。若有未开启的选项，歌词会直接返回而不经过罗马化。")
            ) {
                Toggle("中文歌词罗马化", isOn: $chineseRomanization)
                Toggle("日语歌词罗马化", isOn: $japaneseRomanization)
                Toggle("韩语歌词罗马化", isOn: $koreanRomanization)
            }
        }
        .onChange(of: multiLevelFallback) { newValue in
            UserDefaults.standard.set(newValue, forKey: "ngzhwm_multiLevelLyricsFallback")
        }
        .listStyle(GroupedListStyle())
        .animation(.default, value: multiLevelFallback)
    }
}
