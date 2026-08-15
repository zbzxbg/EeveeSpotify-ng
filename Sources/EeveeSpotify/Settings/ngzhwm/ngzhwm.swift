import SwiftUI

struct NgzhwmSectionView: View {
    var color: Color = .pink
    var title: String = "ngzhwm_title".localized
    var imageSystemName: String = "heart.circle.fill"
    
    var body: some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .foregroundColor(color)
                
                Image(systemName: imageSystemName)
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .medium))
            }
            .frame(width: 30, height: 30)
            
            Text(title)
                .foregroundColor(.white)
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(UIColor.systemGray2))
        }
    }
}