import SwiftUI
import UIKit

// 本项目新增（非 MeloX 移植件）：把 Apple Music 风格歌词页接进 Spotify 的歌词容器。
//
// 门禁：整层 iOS 26+（唯一硬性原因见 `LyricAttributedText.swift` 的说明 ——
// 注册自定义 TextAttribute 需要 iOS 26 的 `attributedTextFormattingDefinition`）。
// 老系统上 `WordByWordHost` 会走原来的 UIKit overlay，行为与改动前完全一致。

// MARK: - 每帧时间源

/// 播放时间的发布者。
///
/// **不自带 CADisplayLink**：由宿主（`WordByWordPlaybackClock`）每帧调用 `submit`，
/// 这样新渲染层和旧 overlay 共用同一个时钟，不存在两套时钟互相错拍的问题。
@available(iOS 26.0, *)
final class AppleMusicLyricsClock: ObservableObject {
    /// 当前播放时间（秒）。每帧更新，驱动整页重绘。
    @Published var playbackTime: TimeInterval = 0
    /// 是否跟随播放（暂停时停止刷新以省电）。
    var isFollowing: Bool = true

    /// 由宿主每帧提交。时间没变就不发通知，省掉一次整页 diff。
    func submit(seconds: TimeInterval) {
        guard isFollowing else { return }
        guard seconds.isFinite else { return }
        guard abs(seconds - playbackTime) > 0.0005 else { return }
        playbackTime = seconds
    }
}

// MARK: - SwiftUI 视图

@available(iOS 26.0, *)
struct AppleMusicLyricsOverlayView: View {

    /// 行模型。换歌时由外部替换。
    let lines: [LyricLine]
    /// 背景（模糊封面等），由外部提供。
    let background: AnyView
    /// 是否显示底部「歌词提供者」。
    let showsProviderFooter: Bool
    /// 左右内边距。
    let sideInset: CGFloat
    /// 点行跳转。
    let onSeek: ((TimeInterval) -> Void)?

    @ObservedObject var clock: AppleMusicLyricsClock

    private static var profile: AppleMusicLyricsMotionProfile { .iOS26_6 }

    var body: some View {
        ZStack {
            background

            if lines.isEmpty {
                // 没有可用行时保持完全透明：让下面的 Spotify 原生歌词透出来，
                // 这比显示一块空背景更不易被误认为「歌词加载失败」。
                Color.clear
            } else {
                AppleMusicLyricsPage(
                    lines: lines,
                    playbackTime: clock.playbackTime,
                    background: AnyView(Color.clear),
                    onClose: nil,
                    onSeek: onSeek,
                    contentInsets: EdgeInsets(
                        top: 8,
                        leading: sideInset,
                        bottom: showsProviderFooter ? 46 : 12,
                        trailing: sideInset
                    )
                )
            }
        }
    }
}

// MARK: - 挂载管理

@available(iOS 26.0, *)
final class AppleMusicLyricsOverlayHost {

    static let shared = AppleMusicLyricsOverlayHost()

    private var hostingController: UIHostingController<AppleMusicLyricsOverlayView>?
    private weak var hostView: UIView?
    private let clock = AppleMusicLyricsClock()
    private var currentLines: [LyricLine] = []
    private var currentVersion: Int = -1
    private var currentSideInset: CGFloat = -1
    private var currentShowsProviderFooter: Bool = false

    private init() {}

    /// 是否应该由本层接管（开关开启 + 系统版本够 + 有词级时间轴）。
    static var isAvailable: Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled else { return false }
        return true
    }

    /// 挂载或刷新。每帧由 `WordByWordPlaybackClock` 调用（和旧 overlay 共用一个入口）。
    func update(
        in view: UIView,
        sideInset: CGFloat,
        showsProviderFooter: Bool
    ) {
        // 数据变了就重建视图（换歌 / 重新取词）。
        if currentVersion != currentLyricsVersion {
            currentVersion = currentLyricsVersion
            currentLines = (currentLyricsDto?.toAppleMusicLyricLines()) ?? []
            writeDebugLog("[AppleMusicLyrics] rebuilt with \(currentLines.count) line(s)")
        }

        let lines = currentLines
        guard !lines.isEmpty else {
            detach()
            return
        }

        // 只在布局参数变化时重建 rootView。
        // 每帧重建虽然不会丢 @ObservedObject 身份（结构一致），但纯属浪费。
        let needsRebuild = sideInset != currentSideInset
            || showsProviderFooter != currentShowsProviderFooter

        if let hostingController,
           hostingController.view.superview === view,
           !needsRebuild {
            return
        }

        currentSideInset = sideInset
        currentShowsProviderFooter = showsProviderFooter

        if let hostingController, hostingController.view.superview === view {
            hostingController.rootView = makeRootView(
                lines: lines,
                sideInset: sideInset,
                showsProviderFooter: showsProviderFooter
            )
            return
        }

        detach()

        let hosting = UIHostingController(
            rootView: makeRootView(
                lines: lines,
                sideInset: sideInset,
                showsProviderFooter: showsProviderFooter
            )
        )
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        // 让 SwiftUI 内容透传触摸：只有歌词行自己是可点的。
        hosting.view.isUserInteractionEnabled = true

        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        hostingController = hosting
        hostView = view
        writeDebugLog("[AppleMusicLyrics] overlay attached (iOS 18+ path)")
    }

    func detach() {
        guard hostingController != nil else { return }
        hostingController?.view.removeFromSuperview()
        hostingController = nil
        hostView = nil
        writeDebugLog("[AppleMusicLyrics] overlay detached")
    }

    /// CADisplayLink 每帧回调入口。由 `WordByWordPlaybackClock.tickHandler` 驱动，
    /// 避免新层自带时钟与主时钟错拍。
    func tick(ms: Double) {
        guard hostView != nil, !currentLines.isEmpty else { return }
        clock.submit(seconds: ms / 1000)
    }

    private func makeRootView(
        lines: [LyricLine],
        sideInset: CGFloat,
        showsProviderFooter: Bool
    ) -> AppleMusicLyricsOverlayView {
        AppleMusicLyricsOverlayView(
            lines: lines,
            background: AppleMusicLyricsBackdrop.makeBackground(),
            showsProviderFooter: showsProviderFooter,
            sideInset: sideInset,
            onSeek: { time in
                WordByWordSeeker.seek(toMs: Int(time * 1000))
            },
            clock: clock
        )
    }
}

// MARK: - 背景

@available(iOS 26.0, *)
enum AppleMusicLyricsBackdrop {
    /// 背景：优先模糊封面（复用已实现的 `LyricsBackdropView` 的取图与缓存逻辑），
    /// 拿不到就退回底色。
    @ViewBuilder
    static func makeBackground() -> AnyView {
        AnyView(
            LyricsBackdropRepresentable()
                .ignoresSafeArea()
        )
    }
}

/// 把已有的 UIKit `LyricsBackdropView` 包进 SwiftUI。复用它的取图/模糊/缓存/材质，
/// 避免同一套封面逻辑存在两份实现。
@available(iOS 26.0, *)
private struct LyricsBackdropRepresentable: UIViewRepresentable {

    func makeUIView(context: Context) -> LyricsBackdropView {
        let view = LyricsBackdropView()
        view.configure(
            baseColor: .black,
            showsArtwork: true,
            material: NgzhwmSettingsViewModel.isLyricsBackdropMaterialEnabled
        )
        return view
    }

    func updateUIView(_ uiView: LyricsBackdropView, context: Context) {}
}
