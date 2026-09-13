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
    /// 背景样式（`.stage` 全屏 / `.card` 预览）。
    ///
    /// ⚠️ 是 `var` 而不是 `let`：全屏 ↔ 预览切换、以及"实心档"变化时，
    /// 都由宿主就地写入，不重建 hosting controller —— 否则整页 SwiftUI 状态
    /// （滚动位置）会被丢掉。背景因此不能像以前那样在构造时固化成 `AnyView`。
    var backdropStyle: LyricsBackdropView.Style
    /// 背景是否走"实心"档（全屏）。
    var solidBackdrop: Bool
    /// 是否显示底部「歌词提供者」。
    ///
    /// ⚠️ 故意是 `var` 而不是 `let`：全屏 ↔ 预览切换时只改这个值 + `sideInset`，
    /// 由 SwiftUI 就地更新布局，**不重建 hosting controller**。
    /// 之前是 `let` + 在 host 里重建 rootView，代价是整页状态（滚动位置）被丢掉，
    /// 于是切屏后歌词回到顶部、不再居中于当前行。
    var showsProviderFooter: Bool
    /// 左右内边距。同样是 `var`，理由见上。
    var sideInset: CGFloat
    /// 预览卡片顶部标题栏的高度（卡片高度 − 歌词视图高度，实测 39pt）。
    ///
    /// 只有预览用：这段高度本来是 Spotify 的标题栏（`歌词` + 分享 + 展开），
    /// 现在由我们自己画（`previewHeader`），所以歌词内容要让出同样多的高度，
    /// 否则会被顶进我们画的标题栏里。
    var previewHeaderInset: CGFloat = 0
    /// 点行跳转。
    let onSeek: ((TimeInterval) -> Void)?
    /// 曲名 / 歌手 —— 自绘壳的标题栏用。
    ///
    /// 不再依赖原生那一页的标题视图（我们连它长什么样都读不到），直接取
    /// `SPTPlayerTrack`。
    ///
    /// ⚠️ 必须是 `var`：`update()` 在宿主没变时会**就地更新**宿主上的属性
    /// （这样才不会重建 hosting controller、丢掉滚动位置）。换歌时标题要跟着变，
    /// 声明成 `let` 就会在那一行报"对不可变属性赋值"。
    var trackTitle: String
    var trackArtist: String

    @ObservedObject var clock: AppleMusicLyricsClock
    /// 播放状态投影（当前时间 / 总时长 / 是否在播放），自绘壳的进度条与播放键用它。
    @ObservedObject var projection: AppleMusicLyricsPlaybackProjection

    private static var profile: AppleMusicLyricsMotionProfile { .iOS26_6 }

    /// 全屏（有壳）时才显示自绘标题栏与播放控制；内嵌预览那一小块不显示。
    private var showsShell: Bool { showsProviderFooter }

    /// 主色：**白色**。
    ///
    /// 与改动前一致（`AppleMusicLyricsPage` 的 `primaryColor` 参数此前没被传过，
    /// 用的就是它的默认值 `.white`）。背景是"模糊封面 + 黑色暗化"，白字是唯一
    /// 在各封面上都稳的选择；歌词、页脚、自绘壳全部共用它，换色时不会漏。
    private let primaryColor: Color = .white

    var body: some View {
        ZStack {
            AppleMusicLyricsBackdrop.makeBackground(
                style: backdropStyle,
                solid: solidBackdrop
            )

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
                        // ⚠️ 预览的底边距必须给够，否则"当前行居中"根本不会发生。
                        //
                        // 机制：ScrollView 只在**内容比视口高**时才能滚；中心对齐靠的是
                        // 滚动偏移。卡片只有 320pt，歌词常常只有三四行（百余点），
                        // 内容比视口矮 → 没有可滚范围 → `scrollTo(anchor: .center)`
                        // 无从生效 → 内容只能贴顶，下面留一片空。
                        // 真机表现就是"歌词那几个框太靠上 + 下面很空"。
                        //
                        // 120 这个值是按最坏情况倒推的：单行歌词也要让内容高过视口，
                        // 这样任何一首歌的当前行都能居中。
                        top: showsProviderFooter ? 8 : 6,
                        leading: sideInset,
                        bottom: showsProviderFooter ? 46 : 120,
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
                    showsProviderFooter: showsProviderFooter,
                    primaryColor: primaryColor,
                    // ⚠️ 两个分支要**各自**包成 AnyView，不能写成
                    // `AnyView(cond ? a : b)`：`a`/`b` 虽然都是 `some View`，
                    // 但是两个不同的具体类型，三元表达式本身没法统一它们
                    // （`AnyView` 是在外面套的，救不了里面）。
                    headerContent: showsProviderFooter ? AnyView(shellHeader) : AnyView(previewHeader),
                    footerContent: showsShell ? AnyView(shellFooter) : nil,
                    closeContent: showsShell ? AnyView(shellClose) : nil,
                    // 全屏：曲名 + 歌手两行（62）；预览：一行「歌词」+ 两个按钮（39，
                    // 由宿主按"卡片高度 − 歌词视图高度"实测传入）。
                    headerHeight: previewHeaderInset > 0 ? previewHeaderInset : 62,
                    // ⚠️ 预览必须传 0：卡片里 `safeArea.top == 0`，再用全屏那套 -30
                    // 会把整条标题栏推到卡片外面 —— 表现就是"预览一个按钮都没有"。
                    headerTopInset: showsProviderFooter ? -30 : 0,
                    // 预览不参与"划动收起壳"：那张小卡片上收起壳只会剩一片空白。
                    hidesShellOnScroll: showsProviderFooter,
                    // 预览：底部淡出按**离底部的固定距离**压住，不再吃比例。
                    //
                    // 卡片只有 320pt，按比例算（0.86）会得到 45pt 的大淡出带；
                    // 而底边距是 120pt（为了让内容可滚、当前行能居中），
                    // 那片空白本来就不该参与淡出 —— 所以起点要落在最后一个可见行附近。
                    fadeBottomOpaqueRatio: showsProviderFooter ? 0.86 : 0.62,
                    // ⚠️ 预览必须传 0：它**没有控件栏**，而淡出遮罩是按
                    // `高度 − footerHeight` 算起点的。写死 116 会让 320pt 高的卡片
                    // 从 y≈204 就开始淡出 —— 这才是"下淡出太高"的真正原因
                    // （注意 `fadeBottomOpaqueRatio` 在预览里其实走不到，
                    // 因为预览也有 headerContent，用的是按壳占位算的 `fadeMaskStops`）。
                    footerHeight: showsProviderFooter ? 116 : 0,
                    // 预览的"底部淡出带"= 0：卡片底部 120pt 是**为了让内容可滚
                    // 而留的空白**（当前行才能居中），在那片空白上淡出等于白淡，
                    // 还会顺手把最后一行也压暗。让歌词一直清晰到卡片下缘即可。
                    fadeBottomBand: showsProviderFooter ? 40 : 0
                )
            }
        }
    }

    // MARK: 自绘壳

    /// 预览卡片顶部那一行：`歌词` + 分享 + 展开。
    ///
    /// 为什么预览也要自己画：卡片面板是 Spotify 的 Element 框架刷的专辑纯色，
    /// 而我们的层是它的子视图 —— **子视图盖不住父视图自己的背景**，
    /// 所以那一行 39pt 永远是粉的（试过五种改法都无效）。
    /// 现在换个思路：把我们的层挂到**卡片容器**上（而不是歌词视图），
    /// 整张卡片都由我们画，"壳"就不存在了。
    ///
    /// 两个按钮的动作转发给原生控件（见 `WordByWordPlaybackControl` 里那两个方法）。
    private var previewHeader: some View {
        HStack(spacing: 0) {
            Text("lyrics".localized)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primaryColor)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                WordByWordPlaybackControl.shareLyrics()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.92))
                    .frame(width: 40, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                WordByWordPlaybackControl.expandToFullscreenLyrics()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.92))
                    .frame(width: 40, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 顶部：曲名 + 歌手（居中，与 Spotify 原生一致）。
    private var shellHeader: some View {
        VStack(spacing: 2) {
            Text(trackTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primaryColor)
                .lineLimit(1)
            Text(trackArtist)
                .font(.system(size: 12))
                .foregroundStyle(primaryColor.opacity(0.72))
                .lineLimit(1)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: .infinity)
    }

    /// 底部：进度条 + 时间 + 播放控制。
    private var shellFooter: some View {
        AppleMusicLyricsControls(
            projection: projection,
            primaryColor: primaryColor,
            onSeek: { onSeek?($0) }
        )
    }

    /// 右上角：关闭全屏页（原生那个 chevron 被我们的背景盖住了，所以自己画一个）。
    private var shellClose: some View {
        Button {
            WordByWordPlaybackControl.dismissFullscreen()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(primaryColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 挂载管理

@available(iOS 26.0, *)
@MainActor
final class AppleMusicLyricsOverlayHost {

    static let shared = AppleMusicLyricsOverlayHost()

    private var hostingController: UIHostingController<AppleMusicLyricsOverlayView>?
    private weak var hostView: UIView?

    /// 当前挂着的 overlay 视图。关闭全屏时要给它拍一张静态替身
    /// （见 `WordByWordHost.handOffToInlineKeepingStandIn`）。
    var overlayView: UIView? { hostingController?.view }
    private let clock = AppleMusicLyricsClock()
    /// 播放状态投影（自绘壳用）。
    ///
    /// 位置来源故意**复用** `WordByWordPositionResolver`，与歌词高亮同一个数据源 ——
    /// 两处各读一次播放器很容易错拍（进度条和歌词差半秒那种）。
    private lazy var projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }
    private var currentLines: [LyricLine] = []
    private var currentVersion: Int = -1
    private var currentSideInset: CGFloat = -1
    private var currentShowsProviderFooter: Bool = false
    /// 当前背景是不是"实心"档（全屏用）。变了要就地更新 rootView。
    private var currentSolidBackdrop: Bool = false
    /// 当前预览卡片标题栏的高度（全屏时为 0）。
    private var currentPreviewHeaderInset: CGFloat = 0
    /// 换歌时要跟着变的壳文本。
    private var currentTrackTitle: String = ""
    private var currentTrackArtist: String = ""

    private init() {}

    /// 是否应该由本层接管（开关开启 + 系统版本够 + 有词级时间轴）。
    static var isAvailable: Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled else { return false }
        return true
    }

    /// 挂载或刷新。挂载时调用一次，之后由 `tick(ms:)` 每帧驱动时间。
    /// - Parameters:
    ///   - view: 挂到哪个视图上。全屏页传 VC 的根视图（整屏），内嵌预览传歌词容器。
    ///   - solidBackdrop: 背景是否走"实心"档（全屏为 true）。
    ///
    ///     ⚠️ 这个参数存在的理由，是那套"接管原生视图"的方案被真机否掉了。
    ///
    ///     最初的目标是"让背景盖住 Spotify 的壳（品红）"。我试过三条路，全错：
    ///       1. 让背景溢出容器 → 不可能，子视图出不了父视图 bounds；
    ///       2. 隐藏原生歌词容器 → 全屏页根视图里**一个子视图都没有**（dump 实测），
    ///          header / 歌词 / 控件栏都不在这一层，藏一个等于藏整页 → 整页空白；
    ///       3. 清宿主底色 + 把整层插到最底 → 摘掉的是这一页**唯一**的背景层
    ///          （dump: `stripped 1 background layer(s): CALayer`）→ 连底都没了。
    ///
    ///     结论：全屏页一个原生视图都不能碰。要盖住底下的东西，只能靠自己够暗 ——
    ///     于是有了这个参数：全屏时把舞台式暗化提到"实心"档（见
    ///     `LyricsBackdropView.solidStageScrimAlpha`），原生 UI 则原样浮在我们上面。
    func update(
        in view: UIView,
        sideInset: CGFloat,
        showsProviderFooter: Bool,
        solidBackdrop: Bool = false,
        previewHeaderInset: CGFloat = 0
    ) {
        // 数据变了就重建视图（换歌 / 重新取词）。
        if currentVersion != currentLyricsVersion {
            currentVersion = currentLyricsVersion
            currentLines = (currentLyricsDto?.toAppleMusicLyricLines()) ?? []
            refreshShellMetadata()
            writeDebugLog("[AppleMusicLyrics] rebuilt with \(currentLines.count) line(s)")
            dumpLinesIfDebugEnabled(currentLines)
        }

        let lines = currentLines
        guard !lines.isEmpty else {
            detach()
            return
        }

        // 宿主没变时**就地更新**，不重建 hosting controller。
        //
        // 之前这里重建 rootView：代价是整页 SwiftUI 状态（滚动位置）被丢掉，
        // 于是全屏 ↔ 预览切换后歌词回到顶部、不再居中于当前行。
        // 改成 var 属性写入后，SwiftUI 只重新计算布局，页面身份与滚动位置都保留。
        let insetChanged = sideInset != currentSideInset
        let footerChanged = showsProviderFooter != currentShowsProviderFooter
        let headerInsetChanged = previewHeaderInset != currentPreviewHeaderInset
        // 全屏 ↔ 预览会换背景档（card ↔ stage，以及实心档），这里要一起处理。
        let backdropChanged = solidBackdrop != currentSolidBackdrop
            || (showsProviderFooter ? LyricsBackdropView.Style.stage : .card)
                != (currentShowsProviderFooter ? .stage : .card)
        // 宿主变了（内嵌预览的歌词容器 → 全屏页的 vc.view）→ 需要**搬**视图，
        // 但依然不重建：`removeFromSuperview` + `addSubview` 会把子视图和约束一起带走，
        // SwiftUI 的页面身份与滚动位置都留着。
        let hostChanged = hostingController?.view.superview !== view

        if let hostingController, !backdropChanged, !hostChanged {
            currentSideInset = sideInset
            currentShowsProviderFooter = showsProviderFooter
            currentSolidBackdrop = solidBackdrop
            currentPreviewHeaderInset = previewHeaderInset

            if insetChanged || footerChanged || headerInsetChanged {
                hostingController.rootView.sideInset = sideInset
                hostingController.rootView.showsProviderFooter = showsProviderFooter
                hostingController.rootView.previewHeaderInset = previewHeaderInset
            }
            // 换歌时壳上的曲名 / 歌手也要跟着换（歌词数据变了就说明换歌了）。
            if hostingController.rootView.trackTitle != currentTrackTitle {
                hostingController.rootView.trackTitle = currentTrackTitle
            }
            if hostingController.rootView.trackArtist != currentTrackArtist {
                hostingController.rootView.trackArtist = currentTrackArtist
            }
            // ⚠️ 每帧置于最前，不只是挂载时。
            //
            // 预览挂在卡片容器上时，卡片里的原生内容（歌词视图、Element 那些层）
            // 会在换帧时重排 subviews，把我们挤回下面 —— 表现就是"壳又被盖住了"。
            // 开销只是一次数组操作。
            if hostingController.view.superview === view {
                view.bringSubviewToFront(hostingController.view)
            }
            return
        }

        let hosting: UIHostingController<AppleMusicLyricsOverlayView>
        if let existing = hostingController, !hostChanged {
            hosting = existing
            // 就地改这些参数：背景是 body 里按它们现算的，所以改完即为最新。
            hosting.rootView.backdropStyle = showsProviderFooter ? .stage : .card
            hosting.rootView.solidBackdrop = solidBackdrop
            hosting.rootView.sideInset = sideInset
            hosting.rootView.showsProviderFooter = showsProviderFooter
            hosting.rootView.previewHeaderInset = previewHeaderInset
            // 壳文本也一起对齐（换歌 + 换挂载点可能同时发生）。
            hosting.rootView.trackTitle = currentTrackTitle
            hosting.rootView.trackArtist = currentTrackArtist
        } else {
            detach()
            hosting = UIHostingController(
                rootView: makeRootView(
                    lines: lines,
                    sideInset: sideInset,
                    showsProviderFooter: showsProviderFooter,
                    solidBackdrop: solidBackdrop,
                    previewHeaderInset: previewHeaderInset
                )
            )
            hosting.view.backgroundColor = .clear
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            // 让 SwiftUI 内容透传触摸：只有歌词行自己是可点的。
            hosting.view.isUserInteractionEnabled = true
        }

        currentSideInset = sideInset
        currentShowsProviderFooter = showsProviderFooter
        currentSolidBackdrop = solidBackdrop

        hosting.view.removeFromSuperview()

        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // ⚠️ 必须**每帧**置于最前，而不只是挂载时。
        //
        // 预览时我们挂在卡片容器上，而卡片里的原生内容（歌词视图、Element 那些层）
        // 会在换帧时重排 subviews —— 一次 `bringSubviewToFront` 会被它们挤回下面，
        // 表现就是"粉杠又回来了 / 我们的壳被盖住"。这里的开销只是一次数组操作。
        view.bringSubviewToFront(hosting.view)

        hostingController = hosting
        hostView = view
        writeDebugLog(
            "[AppleMusicLyrics] overlay attached (Apple Music path)"
                + " host=\(NSStringFromClass(type(of: view)))"
                + " solidBackdrop=\(solidBackdrop)"
                + " shell=\(showsProviderFooter)"
        )

        // 全屏自绘壳挂上后，把"这一刻窗口里所有可点控件 + 每个动作会选中谁"
        // 打进日志。三键的目标是靠标签选的，真机上出现过选错/选空，
        // 这份 dump 是唯一能看清原因的东西。只在开了日志记录时输出。
        if showsProviderFooter {
            WordByWordPlaybackControl.dumpControlCandidates()
        }
    }

    func detach() {
        guard hostingController != nil else { return }
        hostingController?.view.removeFromSuperview()
        hostingController = nil
        hostView = nil
        writeDebugLog("[AppleMusicLyrics] overlay detached")
    }

    /// 换歌时更新壳上的曲名 / 歌手。
    ///
    /// 为什么从 `SPTPlayerTrack` 取而不是从歌词数据：歌词里没有歌手名，
    /// 而曲名在 TTML 里也不一定准（`musicName` 可能是别的语言写法）。
    /// 直接问播放器拿，和手机其他界面显示的一致。
    private func refreshShellMetadata() {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        currentTrackTitle = track?.trackTitle() ?? ""
        currentTrackArtist = (EeveeSpotify.hookTarget == .lastAvailableiOS14
            ? track?.artistTitle()
            : track?.artistName()) ?? ""
        writeDebugLog("[Shell] metadata \"\(currentTrackTitle)\" — \"\(currentTrackArtist)\"")
    }

    // MARK: 为什么不"接管"原生视图

    // 这里曾经有一整套代码：`stripHostBackground` / `restoreHostBackground`
    // （清宿主 backgroundColor 与 layer 上的底色层）、`strippedLayers` /
    // `clearedBaseColors` 两张还原表、`dumpFullscreenHierarchy` /
    // `scheduleFullscreenSecondPass` 诊断、以及把整层 `sendSubviewToBack` 的逻辑。
    //
    // 全部删掉了。真机 + dump 的证据是：全屏页的根视图里**一个子视图都没有**，
    // header / 歌词 / 控件栏都不在这一层，所以
    //   · 隐藏任何一个"看起来像歌词容器"的视图 → 整页内容一起消失（整页空白）；
    //   · 清根视图的底色/层 → 摘掉这一页唯一的背景层，页面连底都没了。
    //
    // 一句话：这一页不是"我们的层 + 它的壳"两层结构，而是一整块我们看不透的视图，
    // 任何"刮掉一层让位"的做法都会把它刮坏。要盖住它，只能靠自己的背景够暗 ——
    // 见 `LyricsBackdropView.solidStageScrimAlpha`。

    /// CADisplayLink 每帧回调入口。由 `WordByWordPlaybackClock.tickHandler` 驱动，
    /// 避免新层自带时钟与主时钟错拍。
    func tick(ms: Double) {
        guard hostView != nil, !currentLines.isEmpty else { return }
        clock.submit(seconds: ms / 1000)
        // 自绘壳的进度条 / 时间 / 播放键状态也走同一个时钟。
        projection.refresh()
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
        showsProviderFooter: Bool,
        solidBackdrop: Bool,
        previewHeaderInset: CGFloat
    ) -> AppleMusicLyricsOverlayView {
        AppleMusicLyricsOverlayView(
            lines: lines,
            backdropStyle: showsProviderFooter ? .stage : .card,
            solidBackdrop: solidBackdrop,
            showsProviderFooter: showsProviderFooter,
            sideInset: sideInset,
            previewHeaderInset: previewHeaderInset,
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
            trackTitle: currentTrackTitle,
            trackArtist: currentTrackArtist,
            clock: clock,
            projection: projection
        )
    }
}

// MARK: - 背景

@available(iOS 26.0, *)
enum AppleMusicLyricsBackdrop {
    /// 背景：模糊封面（复用 `LyricsBackdropView` 的取图与缓存/材质逻辑）。
    ///
    /// `style` 由调用方按「是不是全屏」决定：
    ///   · 全屏 → `.stage`：铺满整屏 + 均匀暗化
    ///   · 预览 → `.card`：只在卡片内，上下暗中间透
    ///
    /// - Parameter solid: 全屏专档。见 `LyricsBackdropView.solidStageScrimAlpha`：
    ///   全屏时背景要负责"压住"底下的原生页面（我们不再动任何原生视图），
    ///   所以需要比默认更实。
    @ViewBuilder
    static func makeBackground(
        style: LyricsBackdropView.Style,
        solid: Bool = false
    ) -> AnyView {
        AnyView(
            LyricsBackdropRepresentable(style: style, solid: solid)
                .ignoresSafeArea()
        )
    }
}

/// 把已有的 UIKit `LyricsBackdropView` 包进 SwiftUI。复用它的取图/模糊/缓存/材质，
/// 避免同一套封面逻辑存在两份实现。
@available(iOS 26.0, *)
private struct LyricsBackdropRepresentable: UIViewRepresentable {

    /// 背景样式：全屏用舞台式（铺满整屏 + 均匀暗化），预览用卡片式。
    let style: LyricsBackdropView.Style
    /// 是否走"实心"档（全屏）。
    let solid: Bool

    func makeUIView(context: Context) -> LyricsBackdropView {
        let view = LyricsBackdropView()
        view.style = style
        view.solid = solid
        // Apple Music 层是"我们替换了原生内容"的那条路：必须不透明，
        // 否则会露出底下 Spotify 原生的歌词与控件，和我们自己画的叠在一起。
        view.isBackdropOpaque = true
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
        uiView.solid = solid
        uiView.isBackdropOpaque = true
    }
}
