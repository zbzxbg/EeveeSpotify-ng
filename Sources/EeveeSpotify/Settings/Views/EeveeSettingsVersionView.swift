import SwiftUI

struct EeveeSettingsVersionView: View {
    @State private var latestVersion: String?
    @State private var isPresentingContributorsSheet = false
    
    private func loadVersion() async throws {
        let release = try await GitHubHelper.shared.getLatestRelease()
        latestVersion = String(release.tagName.dropFirst(5)) // swiftX.X
    }
    
    // 🔽 修改：只有正式版才提示更新
    private var isUpdateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        // 检查是否为测试版（包含 -beta.）
        let isBeta = latest.contains("-beta.")
        // 版本不同 && 不是测试版 → 显示更新
        return latest != EeveeSpotify.version && !isBeta
    }
    
    var body: some View {
        Section {
            if isUpdateAvailable {
                Link(
                    "update_available".localized,
                    destination: URL(string: "https://github.com/zbzxbg/EeveeSpotifyReborn-ng/releases")!  // ✅ 已修改地址
                )
            }
        } footer: {
            VStack(alignment: .leading) {
                Text("v\(EeveeSpotify.version)")
                
                if latestVersion == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("checking_for_update".localized)
                    }
                }
                else {
                    Button("\("contributors".localized)...") {
                        isPresentingContributorsSheet = true
                    }
                    .foregroundColor(.gray)
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
        .sheet(isPresented: $isPresentingContributorsSheet) {
            EeveeContributorsSheetView()
        }
        
        .animation(.default, value: latestVersion)
        
        .onAppear {
            Task {
                try await loadVersion()
            }
        }
    }
}