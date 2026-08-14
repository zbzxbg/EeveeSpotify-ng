import SwiftUI

// 新建文件：ngzhwm.swift
// 这个视图用来在主设置页中显示一个可点击的入口行
// 外观模仿系统设置项：左边彩色图标，中间标题，右边箭头

struct NgzhwmSectionView: View {
    // 颜色：使用粉色，你可以改成任何喜欢的颜色
    // 例如：Color.red、Color.orange、Color(hex: "#FF69B4") 等
    var color: Color = .pink
    
    // 标题：显示的文字，这里固定为“ngzhwm的专属功能”
    var title: String = "ngzhwm的专属功能"
    
    // 图标名称：使用 SF Symbols 中的 heart.circle.fill
    var imageSystemName: String = "heart.circle.fill"
    
    var body: some View {
        HStack(spacing: 15) {
            // 左侧图标框
            ZStack {
                // 圆角矩形背景，圆角大小为 8
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .foregroundColor(color)   // 使用我们定义的颜色
                
                // 图标（白色）
                Image(systemName: imageSystemName)
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .medium))  // 图标大小和粗细与之前一致
            }
            .frame(width: 30, height: 30)   // 固定尺寸 30×30
            
            // 中间标题
            Text(title)
                .foregroundColor(.white)     // 文字白色
            
            Spacer()   // 将右侧箭头推到最右
            
            // 右侧箭头指示器（使用系统自带的 chevron.right）
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(UIColor.systemGray2))   // 灰色箭头，和系统设置类似
        }
    }
}