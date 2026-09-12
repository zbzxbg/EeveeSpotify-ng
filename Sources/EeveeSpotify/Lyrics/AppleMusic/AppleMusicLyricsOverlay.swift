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
    ///
    /// ⚠️ 故意是 `var` 而不是 `let`：全屏 ↔ 预览切换时只改这个值 + `sideInset`，
    /// 由 SwiftUI 就地更新布局，**不重建 hosting controller**。
    /// 之前是 `let` + 在 host 里重建 rootView，代价是整页状态（滚动位置）被丢掉，
    /// 于是切屏后歌词回到顶部、不再居中于当前行。
    var showsProviderFooter: Bool
    /// 左右内边距。同样是 `var`，理由见上。
    var sideInset: CGFloat
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
                        top: showsProviderFooter ? 8 : 6,
                        leading: sideInset,
                        bottom: showsProviderFooter ? 46 : 10,
                        trailing: sideInset
                    ),
                    // 分档按「是不是全屏」决定：
                    // showsProviderFooter 只在全屏页为 true（内嵌预览不显示提供者），
                    // 所以直接拿它当尺度判据，不必再往下传一个额外参数。
                    typography: showsProviderFooter ? .fullscreen : .preview,
                    // 副唱只在全屏页显示：预览是 17pt 的小卡片，
                    // 副唱按 0.63 缩到约 11pt 看不清，还白占一行高度。
                    showsBackgroundVocals: showsProviderFooter,
                    // 歌词提供者页脚：全屏显示，预览不显示（卡片太小）。
                    //
                    // 从全局读而不是做参数，是为了**避免一个能预报的 bug**：
                    // `update()` 在「布局参数没变」时会提前 return，不重建 rootView，
                    // 所以任何存在 view 里、由 host 推入的值在换歌时都会变成陈旧的。
                    // `currentLyricsProvider` 是全局，按需读取天然最新。
                    provider: currentLyricsProvider,
                    showsProviderFooter: showsProviderFooter
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
            dumpLinesIfDebugEnabled(currentLines)
        }

        let lines = currentLines
        guard !lines.isEmpty else {
            detach()
            return
        }

        // 布局参数变化时**就地改属性**，不重建 hosting controller。
        //
        // 之前这里重建 rootView：代价是整页 SwiftUI 状态（滚动位置）被丢掉，
        // 于是全屏 ↔ 预览切换后歌词回到顶部、不再居中于当前行。
        // 改成 var 属性写入后，SwiftUI 只重新计算布局，页面身份与滚动位置都保留。
        if let hostingController, hostingController.view.superview === view {
            let insetChanged = sideInset != currentSideInset
            let footerChanged = showsProviderFooter != currentShowsProviderFooter

            currentSideInset = sideInset
            currentShowsProviderFooter = showsProviderFooter

            if insetChanged || footerChanged {
                hostingController.rootView.sideInset = sideInset
                hostingController.rootView.showsProviderFooter = showsProviderFooter
            }
            return
        }

        currentSideInset = sideInset
        currentShowsProviderFooter = showsProviderFooter
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
        writeDebugLog("[AppleMusicLyrics] overlay attached (Apple Music path)")
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

    /// 逐行打印时间戳与文本，**只在 rebuild 时各打一次**。
    ///
    /// 用途：分辨「一行的文本在数据里就是短的」与「一行被折成了两行」——
    /// 前者是两个独立行对象，后者才是换行算法问题。
    /// 旧实现（`LyricsWordByWordOverlayView`）本来每帧打一条诊断，
    /// 换成新渲染层后那条日志没了，排查时等于盲的。
    ///
    /// 不需要额外的开关：`writeDebugLog` 自己就受设置里的「开启日志记录」控制，
    /// 关着的时候这里一行都不会输出（一次 rebuild 约 65 行，不刷屏）。
    private func dumpLinesIfDebugEnabled(_ lines: [LyricLine]) {
        writeDebugLog("[AppleMusicLyrics] ---- \(lines.count) line(s) ----")
        for (index, line) in lines.enumerated() {
            let start = String(format: "%.2f", line.time)
            let kind = line.syllables.isEmpty ? "line" : "word(\(line.syllables.count))"
            let bg = line.backgroundVocal == nil ? "" : " +bg"
            writeDebugLog(
                "[AppleMusicLyrics] L\(index) t=\(start) \(kind)\(bg) \"\(line.text)\""
            )
        }
        writeDebugLog("[AppleMusicLyrics] ---- end ----")
    }

    private func makeRootView(
        lines: [LyricLine],
        sideInset: CGFloat,
        showsProviderFooter: Bool
    ) -> AppleMusicLyricsOverlayView {
        AppleMusicLyricsOverlayView(
            lines: lines,
            background: AppleMusicLyricsBackdrop.makeBackground(
                // 全屏 → 舞台式背景（铺满整屏）；预览 → 卡片式。
                style: showsProviderFooter ? .stage : .card
            ),
            showsProviderFooter: showsProviderFooter,
            sideInset: sideInset,
            onSeek: { time in
                // ⚠️ 必须 rounded() 而不是 Int() 截断，并额外 +5ms。
                //
                // `line.time` 是 `TimeInterval(offsetMs) / 1000`，双精度存不下
                // 26.622 这种值，会落在略小的一侧（26.621999999999999…）。
                // 再 ×1000 得到 26621.999999999996，`Int()` 截断成 **26621** ——
                // 比这一行的起点少 1 毫秒。而时间轴的判定是 `time <= playbackTime`，
                // 差这 1 毫秒就正好落回**上一行**，于是"点当前行反而定位到上一行"。
                //
                // +5ms 是为了即使有舍入误差或播放器 seek 后回报有轻微滞后，
                // 也稳定落在这一行**内部**而不是边界上。
                let ms = Int((time * 1000).rounded()) + 5
                WordByWordSeeker.seek(toMs: ms)
            },
            clock: clock
        )
    }
}

// MARK: - 背景

@available(iOS 26.0, *)
enum AppleMusicLyricsBackdrop {
    /// 背景：模糊封面（复用 `LyricsBackdropView` 的取图与缓存/材质逻辑）。
    ///
    /// `style` 由调用方按「是不是全屏」决定：
    ///   · 全屏 → `.stage`：溢出铺满整屏 + 均匀暗化，让 Spotify 原有的
    ///     header / 控件栏与歌词落在同一块背景上（消除"壳肉割裂"）
    ///   · 预览 → `.card`：只在卡片内，上下暗中间透
    @ViewBuilder
    static func makeBackground(
        style: LyricsBackdropView.Style
    ) -> AnyView {
        AnyView(
            LyricsBackdropRepresentable(style: style)
                .ignoresSafeArea()
        )
    }
}

/// 把已有的 UIKit `LyricsBackdropView` 包进 SwiftUI。复用它的取图/模糊/缓存/材质，
/// 避免同一套封面逻辑存在两份实现。
@available(iOS 26.0, *)
private struct LyricsBackdropRepresentable: UIViewRepresentable {

    /// 背景样式：全屏用舞台式（溢出铺满 + 均匀暗化），预览用卡片式。
    let style: LyricsBackdropView.Style

    func makeUIView(context: Context) -> LyricsBackdropView {
        let view = LyricsBackdropView()
        view.style = style
        view.configure(
            baseColor: .black,
            showsArtwork: true,
            material: NgzhwmSettingsViewModel.isLyricsBackdropMaterialEnabled
        )
        return view
    }

    func updateUIView(_ uiView: LyricsBackdropView, context: Context) {
        // 内嵌 ↔ 全屏切换时样式会变（stage ↔ card），这里让它跟着走，
        // 不用重建 hosting controller。
        uiView.style = style
    }
}
