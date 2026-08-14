import SwiftUI

// 文件名：ngzhwmTranslate.swift
// 这个页面用于单独设置中文、日语、韩语歌词是否罗马化
struct NgzhwmTranslateView: View {
    
    // 辅助函数：从 UserDefaults 读取开关状态
    // 如果没有保存过，默认返回 true（即默认开启罗马化）
    private func initialValue(for key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        } else {
            return UserDefaults.standard.bool(forKey: key)
        }
    }
    
    // 三个开关的状态变量，初始值从 UserDefaults 读取
    @State private var chineseRomanization: Bool = initialValue(for: "ngzhwmChineseRomanization")
    @State private var japaneseRomanization: Bool = initialValue(for: "ngzhwmJapaneseRomanization")
    @State private var koreanRomanization: Bool = initialValue(for: "ngzhwmKoreanRomanization")
    
    var body: some View {
        List {
            Section {
                // 中文歌词罗马化开关
                Toggle(
                    "中文歌词罗马化",
                    isOn: $chineseRomanization
                )
                .onChange(of: chineseRomanization) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "ngzhwmChineseRomanization")
                }
                
                // 日语歌词罗马化开关
                Toggle(
                    "日语歌词罗马化",
                    isOn: $japaneseRomanization
                )
                .onChange(of: japaneseRomanization) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "ngzhwmJapaneseRomanization")
                }
                
                // 韩语歌词罗马化开关
                Toggle(
                    "韩语歌词罗马化",
                    isOn: $koreanRomanization
                )
                .onChange(of: koreanRomanization) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "ngzhwmKoreanRomanization")
                }
            } footer: {
                // 三个开关下方的说明文字
                Text("单独设置每种语言的歌词是否罗马化，该选项生效需要开启whoeevee菜单内的“罗马化歌词”。若有未开启的选项，歌词会直接返回而不经过罗马化。")
            }
        }
        .listStyle(GroupedListStyle())   // 分组列表样式，与项目其他设置页一致
        .navigationTitle("歌词罗马化")   // 页面标题
    }
}