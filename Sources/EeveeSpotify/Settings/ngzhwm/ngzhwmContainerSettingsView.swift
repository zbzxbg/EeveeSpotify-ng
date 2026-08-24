import SwiftUI

struct NgzhwmContainerSettingsView: View {
    @StateObject var viewModel = NgzhwmSettingsViewModel()
    
    var body: some View {
        List {
            disableLyricsSection()
            lyricsFallbackSection()
            geniusStrictMatchSection()
            romanizationSection()
            // 底部留白：防止最后一项（删除 MxM 间奏符号）的说明 footer 被底部
            // Home 指示条裁掉，列表没有滚动余量只能橡皮筋弹回。
            NonIPadSpacerView()
        }
        .listStyle(GroupedListStyle())
        .animation(.default, value: viewModel.multiLevelFallback)
    }
    
    @ViewBuilder private func disableLyricsSection() -> some View {
        Section(
            footer: Text("ngzhwm_disable_lyrics_feature_description".localized)
        ) {
            Toggle(
                "ngzhwm_disable_lyrics_feature".localized,
                isOn: $viewModel.disableLyricsFeature
            )
        }
    }

    @ViewBuilder private func lyricsFallbackSection() -> some View {
        Section(
            footer: Text("ngzhwm_multi_level_fallback_description".localized)
        ) {
            Toggle(
                "ngzhwm_multi_level_fallback".localized,
                isOn: $viewModel.multiLevelFallback
            )
        }
    }
    
    @ViewBuilder private func geniusStrictMatchSection() -> some View {
        Section(
            footer: Text("ngzhwm_genius_strict_match_description".localized)
        ) {
            Toggle(
                "ngzhwm_genius_strict_match".localized,
                isOn: $viewModel.geniusStrictMatch
            )
        }
    }
    
    @ViewBuilder private func romanizationSection() -> some View {
        Section(
            footer: Text("ngzhwm_romanization_description".localized)
        ) {
            Toggle("ngzhwm_chinese_romanization".localized, isOn: $viewModel.chineseRomanization)
            Toggle("ngzhwm_japanese_romanization".localized, isOn: $viewModel.japaneseRomanization)
            Toggle("ngzhwm_korean_romanization".localized, isOn: $viewModel.koreanRomanization)
        }

        Section(
            footer: Text("ngzhwm_remove_mxm_interlude_symbol_description".localized)
        ) {
            Toggle(
                "ngzhwm_remove_mxm_interlude_symbol".localized,
                isOn: $viewModel.removeMxmInterludeSymbol
            )
        }
    }
}
