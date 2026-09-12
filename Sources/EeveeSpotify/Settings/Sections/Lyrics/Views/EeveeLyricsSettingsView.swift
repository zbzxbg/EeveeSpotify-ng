import SwiftUI

struct EeveeLyricsSettingsView: View {
    @StateObject var viewModel = EeveeLyricsSettingsViewModel()

    var body: some View {
        List {
            wordByWordLyricsSection()

            // 「更好的逐词歌词」是「开启逐词歌词」的子项：**必须紧跟主开关**，
            // 中间不插别的 section。主开关没开时整项不展示
            // （与下面 NetEase 那几项同一套写法）。
            if viewModel.wordByWordLyrics {
                betterWordByWordLyricsSection()
            }

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
                // 「AMLL 优先」需要有一个「用户自己选的源」作为回退目标，
                // 所以来源为 Genius / 多级回退 / LRCLIB / AMLL 时不展示。
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

    /// 「更好的逐词歌词」：**跟着主开关显示/隐藏的子项**，不单独占一个平级位置。
    ///
    /// 与文件里其它条件项同一套写法（例如
    /// `if viewModel.lyricsSource == .netease { ... }`）：
    /// 逐词歌词没开时它没有任何意义，所以整项不展示，而不是置灰。
    ///
    /// 页脚里把"开启后自动带上什么"说清楚，免得用户去找已经不存在的
    /// 模糊封面 / 系统材质开关（那两个已改为跟随本项自动启用）。
    ///
    /// ⚠️ 文案 key 是 `_description` 而不是 `_footer`：本文件里所有页脚都用
    /// `<开关名>_description`（逐词歌词、AMLL 优先、禁用歌词、多级回退……一致）。
    /// 这里曾经多出一个 `ngzhwm_better_word_by_word_lyrics_footer`，是**同一个开关
    /// 两份文案** —— 改文案时只改一处、另一处悄悄过期，正是那种"看起来改过了、
    /// 界面上还是旧话"的坑。现在合并成一条。
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
    
    /// 「AMLL 优先」：勾选后先向 AMLL 要逐词歌词，没正常返回再回退到
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
