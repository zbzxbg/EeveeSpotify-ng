import SwiftUI

// 文件名：ngzhwmLyrics.swift
// 这个页面是一个设置子页面，用于控制“歌词多级回退”功能
struct NgzhwmLyricsView: View {
    
    // 从 UserDefaults 读取开关的初始状态
    // 如果之前没有保存过，默认为 false
    @State private var isEnabled: Bool = UserDefaults.standard.bool(forKey: "ngzhwmLyricsFallbackEnabled")
    
    var body: some View {
        List {
            Section {
                // 开关控件
                Toggle(
                    "歌词多级回退",           // 开关的标题
                    isOn: $isEnabled          // 绑定状态变量
                )
                // 当开关状态改变时触发
                .onChange(of: isEnabled) { newValue in
                    // 将新状态保存到 UserDefaults
                    UserDefaults.standard.set(newValue, forKey: "ngzhwmLyricsFallbackEnabled")
                }
            } footer: {
                // 分组底部的说明文字（显示在方框下方）
                Text("当此选项开启时，歌词将按照Mxm-PL-LRC-Gen的方式多级回退查询展示（每个源最长尝试两秒，若两秒还未返回内容则查询下一个源）。当此选项关闭时，歌词会按照whoeevee菜单内用户的设置进行查询展示。")
            }
        }
        .listStyle(GroupedListStyle())   // 使用分组列表样式，与其他设置页保持一致
        .navigationTitle("歌词多级回退") // 设置页面导航栏标题
    }
}
