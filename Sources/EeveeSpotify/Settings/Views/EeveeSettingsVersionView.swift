import Foundation
import SwiftUI

private enum VersionCheckError: Error {
    case timedOut
    case invalidVersion
}

private struct SemanticVersion: Comparable {
    private enum Identifier: Equatable {
        case numeric(Int)
        case text(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    private let prerelease: [Identifier]

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let withoutBuildMetadata = withoutPrefix.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0]
        let parts = withoutBuildMetadata.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !parts.isEmpty, !parts[0].isEmpty else {
            return nil
        }
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)

        guard core.count == 3,
              let major = Int(core[0]),
              let minor = Int(core[1]),
              let patch = Int(core[2]),
              major >= 0,
              minor >= 0,
              patch >= 0 else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch

        guard parts.count == 2 else {
            self.prerelease = []
            return
        }

        let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard !identifiers.isEmpty,
              identifiers.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        self.prerelease = identifiers.map { identifier in
            if let number = Int(identifier),
               identifier == "0" || !identifier.hasPrefix("0") {
                return .numeric(number)
            }
            return .text(String(identifier))
        }
    }

    var normalized: String {
        let core = "\(major).\(minor).\(patch)"
        guard !prerelease.isEmpty else { return core }

        let suffix = prerelease.map { identifier in
            switch identifier {
            case .numeric(let number):
                return String(number)
            case .text(let text):
                return text
            }
        }.joined(separator: ".")
        return "\(core)-\(suffix)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty
        }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }

            switch (left, right) {
            case (.numeric(let leftNumber), .numeric(let rightNumber)):
                return leftNumber < rightNumber
            case (.numeric, .text):
                return true
            case (.text, .numeric):
                return false
            case (.text(let leftText), .text(let rightText)):
                return leftText < rightText
            }
        }

        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct EeveeSettingsVersionView: View {
    @State private var latestVersion: String?
    @State private var isPresentingContributorsSheet = false
    
    // 限时 15 秒查询最新版本；超时、请求失败或远程标签格式无效时，
    // 都视为查询成功但没有新版本，避免 UI 一直卡在“正在检查更新”。
    private func loadVersion() async {
        do {
            let release = try await withTimeout(seconds: 15) {
                try await GitHubHelper.shared.getLatestRelease()
            }
            guard let version = SemanticVersion(release.tagName) else {
                throw VersionCheckError.invalidVersion
            }
            latestVersion = version.normalized
        } catch let versionCheckError {
            writeDebugLog("[VersionCheck] Failed to fetch latest release: \(versionCheckError)")
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
    
    // 只有远程版本严格高于当前版本时才提示更新。
    private var isUpdateAvailable: Bool {
        guard let latestVersion = latestVersion,
              let latest = SemanticVersion(latestVersion),
              let current = SemanticVersion(EeveeSpotify.version) else {
            return false
        }
        return latest > current
    }
    
    var body: some View {
        Section {
            if isUpdateAvailable {
                Link(
                    "update_available".localized,
                    destination: URL(string: "https://github.com/zbzxbg/EeveeSpotifyReborn-ng/releases")!
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
