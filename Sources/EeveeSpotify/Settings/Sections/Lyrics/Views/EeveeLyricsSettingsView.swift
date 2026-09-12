import SwiftUI

struct EeveeLyricsSettingsView: View {
    @StateObject var viewModel = EeveeLyricsSettingsViewModel()
    
    var body: some View {
        List {
            wordByWordLyricsSection()
            betterWordByWordLyricsSection()
            blurredBackdropSection()
            lyricsSourceSection()
            
            // 「禁用歌词功能」作为「禁用歌词替换功能」的二级菜单：
            // 仅当「禁用歌词替换功能」开启（lyricsSource == .notReplaced）时显示，
            // 写法与下方两个 NetEase 设置的条件显示一致。
            if viewModel.lyricsSource == .notReplaced {
                disableLyricsSection()
            }
            
            if viewModel.lyricsSource == .netease {
                neteaseRomajiLocalSection()
                neteaseHideTranslationSection()
            }
            
            if viewModel.lyricsSource != .notReplaced {
                // 「AMLL TTML 优先」需要有一个「用户自己选的源」作为回退目标，
                // 所以来源为 Genius / 多级回退 / LRCLIB / AMLL TTML 时不展示。
                if viewModel.lyricsSource != .genius
                    && viewModel.lyricsSource != .multiLevel
                    && viewModel.lyricsSource != .lrclib
                    && viewModel.lyricsSource != .amllTtml {
                    amllPreferredSection()
                }
                
                // Genius 回退保持原有条件：多级回退链路本身以 Genius 收尾，
                // 不再重复提供该开关；来源为 Genius 时自己回退给自己没有意义。
                if viewModel.lyricsSource != .genius && viewModel.lyricsSource != .multiLevel {
                    geniusFallbackSection()
                }
                
                hideOnErrorSection()
                romanizationSection()
                
                // 多级回退链路包含 Musixmatch，其语言项同样可配置。
                if viewModel.lyricsSource == .musixmatch || viewModel.lyricsSource == .multiLevel {
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
    
    @ViewBuilder private func betterWordByWordLyricsSection() -> some View {
        Section(
            footer: Text("ngzhwm_better_word_by_word_lyrics_description".localized)
        ) {
            Toggle(
                "ngzhwm_better_word_by_word_lyrics".localized,
                isOn: $viewModel.betterWordByWordLyrics
            )
        }
    }
    
    /// 模糊封面背景：底图用模糊版专辑封面 + 暗化渐变（中间最透，聚焦行所在区域）。
    /// 依赖逐词歌词（背景属于逐字 overlay 的一部分），未开启时整体禁用。
    @ViewBuilder private func blurredBackdropSection() -> some View {
        Section(
            footer: Text("ngzhwm_blurred_backdrop_description".localized)
        ) {
            Toggle(
                "ngzhwm_blurred_backdrop".localized,
                isOn: $viewModel.blurredLyricsBackdrop
            )
            .disabled(!viewModel.wordByWordLyrics)
            
            Toggle(
                "ngzhwm_blurred_backdrop_material".localized,
                isOn: $viewModel.lyricsBackdropMaterial
            )
            .disabled(!viewModel.wordByWordLyrics || !viewModel.blurredLyricsBackdrop)
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
    
    /// 「AMLL TTML 优先」：勾选后先向 AMLL 要逐词歌词，没正常返回再回退到
    /// 用户在来源选择器里设置的那个源。选项依赖逐词歌词，未开启时整体禁用。
    @ViewBuilder private func amllPreferredSection() -> some View {
        Section {
            Toggle(
                "ngzhwm_amll_preferred".localized,
                isOn: $viewModel.amllPreferred
            )
            .disabled(!viewModel.wordByWordLyrics)
        } footer: {
            Text("ngzhwm_amll_preferred_description".localized)
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
