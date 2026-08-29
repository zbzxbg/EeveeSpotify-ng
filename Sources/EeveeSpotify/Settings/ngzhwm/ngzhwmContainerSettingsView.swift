import SwiftUI

struct NgzhwmContainerSettingsView: View {
    @StateObject var viewModel = NgzhwmSettingsViewModel()
    
    var body: some View {
        List {
            disableLyricsSection()
            wordByWordLyricsSection()
            lyricsFallbackSection()
            neteaseRomajiLocalSection()
            neteaseHideTranslationSection()
            removeInterludeSymbolSection()
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

    @ViewBuilder private func wordByWordLyricsSection() -> some View {
        Section(
            footer: Text("ngzhwm_word_by_word_lyrics_description".localized)
        ) {
            Toggle(
                "ngzhwm_word_by_word_lyrics".localized,
                isOn: $viewModel.wordByWordLyrics
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
    
    @ViewBuilder private func neteaseRomajiLocalSection() -> some View {
        Section(
            footer: Text("ngzhwm_netease_romaji_local_description".localized)
        ) {
            Toggle(
                "ngzhwm_netease_romaji_local".localized,
                isOn: $viewModel.neteaseRomajiLocal
            )
        }
    }
    
    @ViewBuilder private func neteaseHideTranslationSection() -> some View {
        Section(
            footer: Text("ngzhwm_netease_hide_translation_description".localized)
        ) {
            Toggle(
                "ngzhwm_netease_hide_translation".localized,
                isOn: $viewModel.neteaseHideTranslation
            )
        }
    }
    
    @ViewBuilder private func removeInterludeSymbolSection() -> some View {
        Section(
            footer: Text("ngzhwm_remove_interlude_symbol_description".localized)
        ) {
            Toggle(
                "ngzhwm_remove_interlude_symbol".localized,
                isOn: $viewModel.removeMxmInterludeSymbol
            )
        }
    }
}
