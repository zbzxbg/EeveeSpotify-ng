import SwiftUI

// 文件名：ngzhwmLyrics.swift
// 这个页面用于管理 ngzhwm 的歌词相关设置
struct NgzhwmLyricsView: View {
    
    // 歌词多级回退开关的状态，从 UserDefaults 读取初始值（默认为 false）
    @State private var isFallbackEnabled: Bool = UserDefaults.standard.bool(forKey: "ngzhwmLyricsFallbackEnabled")
    
    // 三个罗马化开关的状态，分别控制中文、日语、韩语歌词
    @State private var chineseRomanizationEnabled: Bool = UserDefaults.standard.bool(forKey: "ngzhwmChineseRomanizationEnabled")
    @State private var japaneseRomanizationEnabled: Bool = UserDefaults.standard.bool(forKey: "ngzhwmJapaneseRomanizationEnabled")
    @State private var koreanRomanizationEnabled: Bool = UserDefaults.standard.bool(forKey: "ngzhwmKoreanRomanizationEnabled")
    
    var body: some View {
        List {
            // 第一个分组：歌词多级回退
            Section {
                Toggle(
                    "歌词多级回退",
                    isOn: $isFallbackEnabled
                )
                .onChange(of: isFallbackEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "ngzhwmLyricsFallbackEnabled")
                }
            } footer: {
                Text("当此选项开启时，歌词将按照Mxm-PL-LRC-Gen的方式多级回退查询展示（每个源最长尝试两秒，若两秒还未返回内容则查询下一个源）。当此选项关闭时，歌词会按照whoeevee菜单内用户的设置进行查询展示。")
            }
            
            // 第二个分组：三种语言的歌词罗马化（三个开关挨在一起）
            Section {
                Toggle(
                    "中文歌词罗马化",
                    isOn: $chineseRomanizationEnabled
                )
                .onChange(of: chineseRomanizationEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "ngzhwmChineseRomanizationEnabled")
                }
                
                Toggle(
                    "日语歌词罗马化",
                    isOn: $japaneseRomanizationEnabled
                )
                .onChange(of: japaneseRomanizationEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "ngzhwmJapaneseRomanizationEnabled")
                }
                
                Toggle(
                    "韩语歌词罗马化",
                    isOn: $koreanRomanizationEnabled
                )
                .onChange(of: koreanRomanizationEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "ngzhwmKoreanRomanizationEnabled")
                }
            } footer: {
                Text("单独设置每种语言的歌词是否罗马化，该选项生效需要开启whoeevee菜单内的“罗马化歌词”。若有未开启的选项，歌词会直接返回而不经过罗马化。")
            }
        }
        .listStyle(GroupedListStyle())   // 分组列表样式，与原项目一致
        .navigationTitle("ngzhwm 歌词设置")   // 页面导航栏标题，可自行修改
    }
}