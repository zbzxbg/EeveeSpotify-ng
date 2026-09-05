import SwiftUI

struct EeveeLyricsSettingsView: View {
    @StateObject var viewModel = EeveeLyricsSettingsViewModel()
    
    var body: some View {
        List {
            wordByWordLyricsSection()
            disableLyricsSection()
            lyricsSourceSection()
            
            if viewModel.lyricsSource == .netease {
                neteaseRomajiLocalSection()
                neteaseHideTranslationSection()
            }
            
            if viewModel.lyricsSource != .notReplaced {
                if viewModel.lyricsSource != .genius {
                    geniusFallbackSection()
                }
                
                hideOnErrorSection()
                romanizationSection()
                
                if viewModel.lyricsSource == .musixmatch {
                    musixmatchLanguageSection()
                }
            }
            
            removeInterludeSymbolSection()
            
            NonIPadSpacerView()
        }
        .onReceive(viewModel.musixmatchTokenInputAlertPublisher) { showAnonymousTokenOption in
            showMusixmatchTokenAlert(UserDefaults.lyricsSource, showAnonymousTokenOption)
        }
        .listStyle(GroupedListStyle())
        .disabled(viewModel.isRequestingMusixmatchToken)
        .animation(.default, value: viewModel.animationValues)
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
    
    @ViewBuilder private func geniusFallbackSection() -> some View {
        Section {
            Toggle(
                "genius_fallback".localized,
                isOn: $viewModel.lyricsOptions.geniusFallback
            )
            
        } footer: {
            Text("genius_fallback_description"
                .localizeWithFormat(viewModel.lyricsSource.description))
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
    }

    @ViewBuilder private func hideOnErrorSection() -> some View {
        Section {
            Toggle(
                "hide_lyrics_on_error".localized,
                isOn: $viewModel.lyricsOptions.hideOnError
            )
        } footer: {
            Text("hide_lyrics_on_error_description".localized)
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

    @ViewBuilder private func musixmatchLanguageSection() -> some View {
        Section {
            HStack {
                Text("musixmatch_language".localized)
                
                Spacer()
                
                TextField("en", text: $viewModel.lyricsOptions.musixmatchLanguage)
                    .frame(maxWidth: 20)
                    .foregroundColor(.gray)
            }
            .icon(
                "exclamationmark.triangle.fill",
                color: .yellow,
                when: $viewModel.showMusixmatchInvalidLanguageWarning
            )
        } footer: {
            Text("musixmatch_language_description".localized)
        }
    }
}
