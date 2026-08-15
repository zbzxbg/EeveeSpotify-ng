import SwiftUI

struct NgzhwmContainerSettingsView: View {
    @StateObject var viewModel = NgzhwmSettingsViewModel()
    
    var body: some View {
        List {
            lyricsFallbackSection()
            romanizationSection()
        }
        .listStyle(GroupedListStyle())
        .animation(.default, value: viewModel.multiLevelFallback)
    }
    
    @ViewBuilder private func lyricsFallbackSection() -> some View {
        Section(
            footer: Text("当此选项开启时，歌词将按照Mxm-PL-LRC-Gen的方式多级回退查询展示（每个歌词源最长尝试两秒，若两秒还未返回有效歌词则查询下一个歌词源）。当此选项关闭时，歌词会按照whoeevee菜单内用户的设置进行查询展示。")
        ) {
            Toggle(
                "歌词多级回退",
                isOn: $viewModel.multiLevelFallback
            )
        }
    }
    
    @ViewBuilder private func romanizationSection() -> some View {
        Section(
            footer: Text("单独设置每种语言的歌词是否罗马化，选项生效需要开启whoeevee菜单内的“罗马化歌词”。若有未开启的选项，歌词会直接返回而不经过罗马化。")
        ) {
            Toggle("中文歌词罗马化", isOn: $viewModel.chineseRomanization)
            Toggle("日语歌词罗马化", isOn: $viewModel.japaneseRomanization)
            Toggle("韩语歌词罗马化", isOn: $viewModel.koreanRomanization)
        }
    }
}
