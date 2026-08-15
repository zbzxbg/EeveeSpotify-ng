import SwiftUI

struct NgzhwmContainerSettingsView: View {
    @StateObject var viewModel = NgzhwmSettingsViewModel()
    
    var body: some View {
        List {
            disableLyricsSection()
            lyricsFallbackSection()
            romanizationSection()
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
