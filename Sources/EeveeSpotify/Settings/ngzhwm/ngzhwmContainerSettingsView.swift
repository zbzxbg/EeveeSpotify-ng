
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
    }
}
