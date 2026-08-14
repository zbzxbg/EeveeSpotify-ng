import SwiftUI

struct NgzhwmLyricsSettingsView: View {
    @State private var multiLevelFallback: Bool = UserDefaults.standard.bool(forKey: "ngzhwm_multiLevelLyricsFallback")
    
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
        }
        .onChange(of: multiLevelFallback) { newValue in
            UserDefaults.standard.set(newValue, forKey: "ngzhwm_multiLevelLyricsFallback")
        }
        .listStyle(GroupedListStyle())
        .animation(.default, value: multiLevelFallback)
    }
}