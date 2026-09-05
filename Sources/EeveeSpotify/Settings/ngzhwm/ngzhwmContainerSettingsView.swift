import SwiftUI

struct NgzhwmContainerSettingsView: View {
    // 所有设置已并入「歌词」页面，此页面暂为空。
    // 如需恢复，可在下方 List 中重新添加 Section。
    
    var body: some View {
        List {
            // 底部留白：防止最后一项的说明 footer 被底部 Home 指示条裁掉，
            // 列表没有滚动余量只能橡皮筋弹回。
            NonIPadSpacerView()
        }
        .listStyle(GroupedListStyle())
    }
}
