import SwiftUI

private enum VersionCheckError: Error {
    case timedOut
}

struct EeveeSettingsVersionView: View {
    @State private var latestVersion: String?
    @State private var isPresentingContributorsSheet = false
    
    // 限时 15 秒查询最新版本；超时或请求失败都视为"假装查询成功、且没有新版本"，
    // 避免 UI 一直卡在"正在检查更新"。
    private func loadVersion() async {
        do {
            let release = try await withTimeout(seconds: 15) {
                try await GitHubHelper.shared.getLatestRelease()
            }
            latestVersion = String(release.tagName.dropFirst(5)) // swiftX.X
        } catch {
            latestVersion = EeveeSpotify.version
        }
    }
    
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw VersionCheckError.timedOut
            }
            
            guard let result = try await group.next() else {
                throw VersionCheckError.timedOut
            }
            group.cancelAll()
            return result
        }
    }
    
    // 版本不同即提示更新（不再区分是否测试版）
    private var isUpdateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return latest != EeveeSpotify.version
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
                await loadVersion()
            }
        }
    }
}