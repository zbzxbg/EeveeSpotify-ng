import SwiftUI
import UIKit

// 本项目新增（非 MeloX 移植件）：Apple Music 风格全屏歌词页。
//
// 分层：
//   AppleMusicLyricsContainerView — UIViewRepresentable 包装的宿主，
//                                   内部用 CADisplayLink 驱动播放时间。
//   AppleMusicLyricsPage          — 纯 SwiftUI 视图，消费行模型 + 播放时间。
//
// 为什么自己开 CADisplayLink 而不是用 MeloX 的 `TimelineView(.animation)`：
//   MeloX 用 TimelineView 是因为它没有别的时钟。本项目已经有经过真机验证的
//   `WordByWordPositionResolver`（日志里 `pos sample` 可见其在正常工作），
//   自己驱动可以把「读播放位置」和「刷新视图」合成一次，避免两套时钟互相错拍。

// MARK: - 播放时间驱动

/// 固定频率重绘的宿主视图。`onTick` 在每帧被调用，参数为当前播放秒数。
@available(iOS 26.0, *)
final class AppleMusicLyricsTickView: UIView {

    private var displayLink: CADisplayLink?
    var onTick: ((TimeInterval) -> Void)?
    /// 播放位置来源。返回 nil 时保持上一次的值（例如切歌瞬间解析器还没就绪）。
    var positionProvider: (() -> TimeInterval?)?
    /// 暂停时不再触发重绘（省电）；恢复时先补一次。
    var isPaused: Bool = false {
        didSet {
            guard isPaused != oldValue else { return }
            displayLink?.isPaused = isPaused
            if !isPaused { lastPosition = nil }
        }
    }

    private var lastPosition: TimeInterval?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard !isPaused else { return }
        let position = positionProvider?() ?? lastPosition ?? 0
        lastPosition = position
        onTick?(position)
    }

    deinit {
        displayLink?.invalidate()
    }
}

// MARK: - 全屏歌词页

@available(iOS 26.0, *)
struct AppleMusicLyricsPage: View {

    let lines: [LyricLine]
    /// 每帧变化的播放时间（秒）。
    let playbackTime: TimeInterval
    /// 背景（由调用方决定是模糊封面还是纯色）。
    let background: AnyView
    /// 关闭按钮回调（为 nil 时不显示关闭按钮）。
    let onClose: (() -> Void)?
    /// 点某一行跳转（为 nil 时不可点）。
    let onSeek: ((TimeInterval) -> Void)?
    /// 顶部/底部无障碍内边距。
    let contentInsets: EdgeInsets
    /// 排版分档（全屏 / 预览两种尺度）。
    let typography: LyricsTypographyScale
    /// 是否显示副唱（背景人声）。预览模式传 false。
    let showsBackgroundVocals: Bool
    /// 是否显示行译文。Apple Music 歌词层一律 false。
    let showsTranslation: Bool
    /// 歌词提供者（形如 `"AMLL (EeveeSpotify)"`）。为空则不显示页脚。
    let provider: String
    /// 是否显示歌词提供者页脚。内嵌预览容器太小，不显示。
    let showsProviderFooter: Bool
    /// 主色（歌词文字与页脚共用）。
    ///
    /// 每一行会把它继续传给 `SynchronizedLyricText`；页脚也用它（取一个低不透明度），
    /// 这样"页脚"和"歌词"在同一个色系里，换主题色时不会漏掉页脚。
    let primaryColor: Color
    /// 顶部固定内容（自绘的标题栏）。全屏时传入，内嵌预览为 nil。
    ///
    /// 为什么是内容而不是写死在这里：内嵌预览**没有壳**（那一块小卡片不该出现
    /// 标题栏和播放键），全屏才有。用 `AnyView` 而不是泛型参数，是为了不给
    /// `AppleMusicLyricsPage` 加第二个泛型参数（它已经被 `SomeView` 各处引用）。
    let headerContent: AnyView?
    /// 底部固定内容（自绘的进度条 + 播放控制）。全屏时传入，内嵌预览为 nil。
    let footerContent: AnyView?
    /// 右上角的自绘关闭键。给了它就顶掉内置的 `onClose` 圆按钮。
    ///
    /// 复用这个位置而不是另起一个浮层：它本来就在页面右上角、已经算过安全区，
    /// 再叠一层只会多一份要维护的坐标。
    let closeContent: AnyView?

    init(
        lines: [LyricLine],
        playbackTime: TimeInterval,
        background: AnyView,
        onClose: (() -> Void)? = nil,
        onSeek: ((TimeInterval) -> Void)? = nil,
        contentInsets: EdgeInsets = EdgeInsets(top: 60, leading: 24, bottom: 120, trailing: 24),
        typography: LyricsTypographyScale = .fullscreen,
        showsBackgroundVocals: Bool = true,
        showsTranslation: Bool = false,
        provider: String = "",
        showsProviderFooter: Bool = false,
        primaryColor: Color = .white,
        headerContent: AnyView? = nil,
        footerContent: AnyView? = nil,
        closeContent: AnyView? = nil,
        headerHeight: CGFloat = 62,
        headerTopInset: CGFloat = -30,
        hidesShellOnScroll: Bool = true,
        fadeBottomOpaqueRatio: CGFloat = 0.86,
        footerHeight: CGFloat = 116,
        fadeBottomBand: CGFloat = 40
    ) {
        self.lines = lines
        self.playbackTime = playbackTime
        self.background = background
        self.onClose = onClose
        self.onSeek = onSeek
        self.contentInsets = contentInsets
        self.typography = typography
        self.showsBackgroundVocals = showsBackgroundVocals
        self.showsTranslation = showsTranslation
        self.provider = provider
        self.showsProviderFooter = showsProviderFooter
        self.primaryColor = primaryColor
        self.headerContent = headerContent
        self.footerContent = footerContent
        self.closeContent = closeContent
        self.headerHeight = headerHeight
        self.headerTopInset = headerTopInset
        self.hidesShellOnScroll = hidesShellOnScroll
        self.fadeBottomOpaqueRatio = fadeBottomOpaqueRatio
        self.footerHeight = footerHeight
        self.fadeBottomBand = fadeBottomBand
    }

    private static var profile: AppleMusicLyricsMotionProfile { .iOS26_6 }

    /// 用户滚动后暂停自动跟随的截止时间。
    ///
    /// 这套机制是从旧 overlay（`LyricsWordByWordOverlayView.autoScrollPauseUntil`）
    /// 搬过来的——新层最初漏了它，表现为"手指一离开就被拉回当前行"。
    /// 旧实现的取值：拖动中 3s、松手/减速结束各 2s；SwiftUI 这边只能拿到
    /// "正在拖动"，所以用一个足够长的窗口覆盖松手后的惯性滚动。
    @State private var autoScrollPauseUntil: Date = .distantPast
    /// 拖动手势上一次活跃的时间，用来判断"用户刚松手"。
    @State private var lastDragTime: Date = .distantPast
    /// 上一次自动滚动的时间，用于给连续点击节流（避免多段动画互相打断）。
    @State private var lastAutoScrollTime: Date = .distantPast
    /// 用户松手后继续暂停自动跟随的时长。
    private let postDragPauseDuration: TimeInterval = 2
    /// 两次自动滚动之间的最小间隔。
    private let minimumAutoScrollInterval: TimeInterval = 0.35

    // MARK: 壳的占位 / 淡出带

    /// 底部淡出带高度：从「控件栏上方这么多」开始渐隐，到「控件栏顶部」完全透明。
    ///
    /// ⚠️ 预览传 0：它底部的 120pt 是**为了让内容可滚而留的空白**（当前行才能居中），
    /// 在那片空白上淡出等于白淡 —— 反而会把最后一行也一起吃掉。
    /// 预览就让 lyrics 一直清晰到卡片下缘。
    var fadeBottomBand: CGFloat = 40

    // MARK: 划动时收起壳

    /// 自绘标题栏的实际高度。默认是全屏那套（曲名 + 歌手 ≈ 62）。
    ///
    /// 内嵌预览传"卡片标题栏高度"（卡片高度 − 歌词视图高度，实测 39pt）——
    /// 预览的标题栏只有一行「歌词」+ 两个按钮，跟全屏那两行文字不是一个高度，
    /// 写死 62 会把预览的歌词往下推一截。
    let headerHeight: CGFloat

    /// 标题栏顶端相对安全区的偏移。**负数 = 往上抬**。
    ///
    /// 全屏默认 -30：那一页标题上方本来就有 Spotify 自己的留白，抬一点才对得上。
    /// ⚠️ **内嵌预览必须传 0**：卡片里 `safeArea.top == 0`，再抬 -30 就把整条标题栏
    /// 推到卡片外面去 —— 真机上表现就是"预览歌词一个按钮都没有"（标题栏整个被裁掉）。
    var headerTopInset: CGFloat = -30

    /// 底部壳的高度（淡出遮罩拿它算"从哪开始淡"）。
    ///
    /// 全屏 = 116（进度条 + 时间 + 三键）；**内嵌预览 = 0**（它没有控件栏）。
    /// 写死 116 时，320pt 高的预览卡片会从 y≈204 就开始淡出 —— 那正是
    /// "下淡出太高"的原因。注意这条路径与 `fadeBottomOpaqueRatio` **无关**：
    /// 预览现在也有 `headerContent`，走的是按壳占位算的 `fadeMaskStops`。
    var footerHeight: CGFloat = 116

    /// 是否启用"划动时收起壳"（收起即「全屏歌词」）。
    ///
    /// 只有全屏要这个行为；内嵌预览是一张小卡片，收起壳只会剩一片空白，
    /// 而且"停下不动就淡出 / 划动就收起"那套在预览里没有意义。
    var hidesShellOnScroll: Bool = true

    /// 自绘的壳（标题栏 + 控件栏）是否被划动收起 —— 收起即「全屏歌词」。
    @State private var isShellHidden = false
    /// 待执行的「把壳调回来」任务；再次划动时取消，避免刚抬手就被旧定时器拉回来。
    @State private var shellRestoreTask: Task<Void, Never>?
    /// 松手后多久把壳调回来（这个窗口同时覆盖了松手后的惯性滚动阶段）。
    private let shellRestoreDelay: TimeInterval = 2

    /// 壳当前是否真的不可见（预览里 `hidesShellOnScroll == false`，永远可见）。
    private var isShellEffectivelyHidden: Bool {
        hidesShellOnScroll && isShellHidden
    }

    /// **无壳兜底路径**的顶部淡出结束位置（视口高度比例）—— 取自
    /// MeloX 的 `topOpaque: 0.08`。全屏有壳时不用它，改用 `fadeMaskStops`
    /// 按壳的真实占位算。
    var fadeTopRatio: CGFloat = 0.08
    /// **无壳兜底路径**的底部开始淡出位置。MeloX 用 0.84。
    ///
    /// ⚠️ 这是**比例**，所以容器越矮、淡出带越大：全屏 896pt 时 0.84 对应
    /// 约 143pt 的淡出带，看着正常；预览卡片只有 320pt，同样比例就变成
    /// **64pt 的淡出带**，占了卡片五分之一 —— 真机表现就是"预览的下淡出太高"。
    /// 预览传一个更大的值（更晚开始淡出），把带子压回合理高度。
    var fadeBottomOpaqueRatio: CGFloat = 0.86

    /// 当前播放位置（由纯逻辑时间轴给出，不在这里自己算）。
    private var position: LyricPlaybackPosition {
        LyricPlaybackTimeline.position(at: playbackTime, in: lines)
    }

    var body: some View {
        // 用 GeometryReader 量出**真实可用宽度**再传下去。
        // 之前直接把 constrainedWidth 传 nil、指望 SwiftUI 从父容器推断，
        // 结果是文字不换行、直接超出屏幕宽度（尤其是 36pt 的英文长句）。
        // 同时这也让 `LyricLineFitting` 的超宽缩放修正重新生效。
        GeometryReader { geometry in
            let availableWidth = max(
                geometry.size.width
                    - contentInsets.leading
                    - contentInsets.trailing,
                1
            )
            // 自绘壳占掉的高度：从安全区再往里让，避免歌词钻到标题栏/控件栏底下。
            //
            // 62 / 116 是量出来的，不是拍的：
            //   顶部 = 标题(15pt 一行) + 歌手(12pt 一行) + 间距 ≈ 40，再留 22 呼吸
            //   底部 = 进度条(11) + 时间行(11+3) + 间距(12) + 三键(56) ≈ 100，再留 16
            // 这两块**不参与滚动**，所以它们的高度必须在这里一次性让出来。
            let safeArea = geometry.safeAreaInsets
            let scrollInsets = EdgeInsets(
                top: (headerContent == nil
                    ? contentInsets.top
                    : safeArea.top + headerHeight) + contentInsets.top,
                leading: contentInsets.leading,
                bottom: (footerContent == nil
                    ? contentInsets.bottom
                    : safeArea.bottom + footerHeight) + contentInsets.bottom,
                trailing: contentInsets.trailing
            )

            // 上下淡出带的渐变停靠点。
            //   上：从「歌曲标题顶部」透明 → 到「歌手名字下方」完全不透明
            //   下：从「控件栏上方 fadeBottomBand」完全不透明 → 到「控件栏顶部」透明
            // 中间整段清晰。以前直接用整屏比例（0.08 / 0.80 / 1.0），淡出落在整屏的
            // 顶和底，跟壳的位置没关系 —— 现在改成按壳的真实占位算。
            let maskStops = fadeMaskStops(size: geometry.size, safeArea: safeArea)

            ZStack {
                background
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(
                            alignment: .leading,
                            // 行块之间用「行距 + 一点额外留白」，而不是 Apple Music
                            // 全屏页那个 39pt 段间距 —— 那个在短容器里会把一屏的行数
                            // 压到只剩 3 行。
                            spacing: typography.lineSpacing
                                + max(typography.lineSpacing * 0.6, 4)
                        ) {
                            ForEach(lines) { line in
                                row(
                                    for: line,
                                    position: position,
                                    availableWidth: availableWidth,
                                    proxy: proxy
                                )
                                .id(line.id)
                            }

                            // 歌词提供者页脚。
                            //
                            // 放在列表末尾（与旧 overlay、Spotify 原生一致）：用户往下翻
                            // 才看到，不翻就看不到。**不参与卡拉OK** —— 它不挂 renderer、
                            // 不挂焦点、不模糊、不填充，因为
                            //   1. 它不是"唱出来的内容"，不该有时间轴；
                            //   2. 一旦走焦点逻辑，非焦点行的 0.175 透明度 + 3.5pt 模糊
                            //      会把它糊得不可读。
                            if showsProviderFooter, !provider.isEmpty {
                                providerFooter
                            }
                        }
                        .padding(.top, scrollInsets.top)
                        .padding(.bottom, scrollInsets.bottom)
                        .padding(.horizontal, scrollInsets.leading)
                    }
                    // ⚠️ 进入时必须**无条件**定位一次。
                    //
                    // `onChange` 只在值**变化**时触发：首次渲染时当前行已经就是高亮行，
                    // 所以它永远不会为"初始这一行"跑一次 —— 结果全屏打开、或从预览切回全屏
                    // 时，歌词停在最顶上而不是当前行。
                    // 旧 overlay 没这个问题：它首帧 `activeLineIndex = -1`，
                    // 必然走一次 `scrollToLine`。
                    .onAppear {
                        // 与 onChange 同理：首行之前高亮为 nil，这里要落到**第一行**上，
                        // 否则全屏打开时若歌曲还在前奏，歌词会停在列表顶部。
                        guard let id = position.highlightedLyricID ?? lines.first?.id else { return }
                        // 延后一帧再滚：`LazyVStack` 是先物化可见区域再响应 scrollTo 的，
                        // 在 onAppear 里立刻调用时目标行往往还没生成，会静默失效。
                        // 延后一帧仍然是不带动画的落位。
                        Task { @MainActor in
                            proxy.scrollTo(id, anchor: .center)
                            lastAutoScrollTime = Date()
                        }
                    }
                    .onChange(of: position.highlightedLyricID) { _, newValue in
                        // ⚠️ `nil` 不是"没事发生"：它表示播放位置落在**第一行之前**
                        // （按上一首回到本曲开头、或把进度拖到 0，而首行要几秒后才开始）。
                        // 旧写法 `guard let newValue else { return }` 把这一路直接吞掉，
                        // 表现就是"回到开头时歌词不跟着回第一行"。
                        guard let targetID = newValue ?? lines.first?.id else { return }

                        // 回到开头这一路**绕过节流**：之后高亮会一直停在 nil（前奏可能
                        // 十几秒），被节流吞掉就没有第二次补滚的机会。这里只避开"手指还在拖"。
                        if newValue == nil {
                            guard Date().timeIntervalSince(lastDragTime) > 0.15 else { return }
                        } else {
                            guard shouldAutoScroll() else { return }
                        }

                        lastAutoScrollTime = Date()
                        withAnimation(
                            .spring(
                                duration: 0.5,
                                bounce: 0.08,
                                blendDuration: 0
                            )
                        ) {
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                    // 滚动打断保护：用户一碰就暂停自动跟随。
                    //
                    // SwiftUI 的 DragGesture 只有 onChanged/onEnded，拿不到
                    // UIScrollView 那套 willBeginDragging / didEndDecelerating，
                    // 所以用"最后一次拖动时间 + 固定窗口"近似覆盖惯性滚动阶段。
                    //
                    // 同一对手势顺带负责「划动时收起壳」：划动中立刻收起（＝全屏歌词），
                    // 松手后 `shellRestoreDelay` 秒再调回来。
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { _ in
                                lastDragTime = Date()
                                autoScrollPauseUntil = Date()
                                    .addingTimeInterval(postDragPauseDuration)
                                hideShellWhileScrolling()
                            }
                            .onEnded { _ in
                                lastDragTime = Date()
                                autoScrollPauseUntil = Date()
                                    .addingTimeInterval(postDragPauseDuration)
                                scheduleShellRestore()
                            }
                    )
                    // 上下边缘淡出。
                    //
                    // 这是旧 overlay 有、而我移植时漏掉的一块（它用两个
                    // `topFadeView` / `bottomFadeView` 渐变层实现）。
                    // 这里改用 MeloX 的做法：**遮罩歌词内容本身**，背景不参与 ——
                    // 这样不会出现"背景渐变换色 + 内容渐变"两层叠加变脏的问题。
                    //
                    // 停靠点：有壳（全屏）时按壳的真实占位算，见 `fadeMaskStops`；
                    // 无壳（内嵌预览）时退回 MeloX 的整屏比例 0.08 / 0.84 / 1.0。
                    .mask(
                        LinearGradient(
                            stops: maskStops,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                // 右上角：自绘关闭键优先，其次才是内置的圆按钮。
                // 划动收起壳时它一起淡出 ——「全屏歌词」不该还留着一个按钮。
                if let closeContent {
                    VStack {
                        HStack {
                            Spacer()
                            closeContent
                        }
                        Spacer()
                    }
                    .padding(.top, safeArea.top + 6)
                    .padding(.trailing, 12)
                    .opacity(isShellEffectivelyHidden ? 0 : 1)
                    .allowsHitTesting(!isShellEffectivelyHidden)
                } else if let onClose {
                    closeButton(onClose)
                }

                // 自绘的壳：标题栏固定在顶部、播放控制固定在底部。
                //
                // 这两块**不参与滚动**，所以它们不走 `scrollInsets`，而是直接贴在
                // 安全区边缘；歌词的留白由 `scrollInsets` 负责让出来。
                //
                // 划动歌词时整块淡出（＝全屏歌词），松手 `shellRestoreDelay` 秒后回来。
                // 用透明度而不是 `if`：`if` 会把两块从层级里摘掉，歌词的可视高度跟着
                // 变化、滚动位置会在收起/恢复之间跳一下。
                VStack(spacing: 0) {
                    if let headerContent {
                        headerContent
                            .padding(.top, safeArea.top + headerTopInset)
                    }
                    Spacer(minLength: 0)
                    if let footerContent {
                        footerContent
                            .padding(.bottom, max(safeArea.bottom, 8))
                    }
                }
                .opacity(isShellEffectivelyHidden ? 0 : 1)
                .allowsHitTesting(!isShellEffectivelyHidden)
            }
        }
    }

    /// 是否允许此刻自动滚动。
    ///
    /// 两道闸门，都是从旧 overlay 的行为反推的：
    ///   1. **用户滚动暂停窗口**（对应旧的 `autoScrollPauseUntil`）：
    ///      拖动中与松手后的窗口期内绝不自动滚动，否则手感是"被拽回去"。
    ///   2. **自动滚动节流**（旧的 0.2s 定长动画隐含了这个效果）：
    ///      新层用 0.5s spring，若位置每帧更新都触发一次，多段动画会互相打断，
    ///      最终停在不确定的位置——表现为"点下一行却停在上一行附近"。
    private func shouldAutoScroll() -> Bool {
        let now = Date()
        guard now >= autoScrollPauseUntil else { return false }
        // 还在拖动中（上一次拖动时间非常近）也不要动。
        guard now.timeIntervalSince(lastDragTime) > 0.15 else { return false }
        guard now.timeIntervalSince(lastAutoScrollTime) >= minimumAutoScrollInterval else {
            return false
        }
        return true
    }

    // MARK: 划动时收起 / 恢复壳

    /// 划动中：立刻把壳收起来（标题栏 + 控件栏 + 关闭键淡出），歌词即为全屏。
    ///
    /// 预览卡片不参与这个行为（`hidesShellOnScroll == false`）—— 那张卡片上
    /// 收起壳只会剩一片空白。
    private func hideShellWhileScrolling() {
        guard hidesShellOnScroll else { return }
        shellRestoreTask?.cancel()
        shellRestoreTask = nil
        guard !isShellHidden else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            isShellHidden = true
        }
    }

    /// 松手：`shellRestoreDelay` 秒后把壳调回来。
    ///
    /// 用「延迟任务」而不是立即恢复，是因为 SwiftUI 拿不到惯性滚动的结束时机
    /// （见上面 DragGesture 那段说明）—— 这个固定窗口同时也盖住了减速阶段。
    private func scheduleShellRestore() {
        guard hidesShellOnScroll else { return }
        shellRestoreTask?.cancel()
        shellRestoreTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(shellRestoreDelay * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.22)) {
                isShellHidden = false
            }
        }
    }

    // MARK: 淡出遮罩停靠点

    /// 改动前的整屏比例停靠点（MeloX 口径）。
    ///
    /// 两个场合用它：内嵌预览（本来就没有壳），以及**划动把壳收起**时的全屏歌词 ——
    /// 壳收起后歌词占满整屏，再按壳的占位去算，淡出带会被挤到上下一小块里。
    private var legacyFadeStops: [Gradient.Stop] {
        [
            .init(color: .clear, location: 0),
            .init(color: .black, location: fadeTopRatio),
            .init(color: .black, location: fadeBottomOpaqueRatio),
            .init(color: .clear, location: 1),
        ]
    }

    /// 上下淡出带的渐变停靠点（相对滚动视图高度，取值 0…1）。
    ///
    /// 有壳且**没被收起**时的口径：
    ///   · 上淡出：标题顶部（透明）→ 标题栏底部（不透明）
    ///   · 下淡出：控件栏顶部上方 `fadeBottomBand`（不透明）→ 控件栏顶部（透明）
    /// 中间整段保持完全不透明 —— 也就是"歌词只在标题栏下方到控件栏上方之间淡出"，
    /// 而不是像以前那样贴在整屏的顶和底。
    ///
    /// 无壳（内嵌预览）或壳被划动收起时，退回 `legacyFadeStops`（改动前的整屏比例）。
    private func fadeMaskStops(
        size: CGSize,
        safeArea: EdgeInsets
    ) -> [Gradient.Stop] {
        let height = max(size.height, 1)

        guard headerContent != nil || footerContent != nil,
              !isShellEffectivelyHidden else {
            return legacyFadeStops
        }

        let headerTop = safeArea.top + headerTopInset
        let headerBottom = safeArea.top + headerHeight
        let footerTop = height - (safeArea.bottom + footerHeight)
        let bottomFadeStart = footerTop - fadeBottomBand

        // 位置必须单调不减，否则 LinearGradient 会出现硬边（小屏 / 大字号时可能越界）。
        let topClear = min(max(headerTop / height, 0), 1)
        let topOpaque = min(max(headerBottom / height, topClear), 1)
        let bottomOpaque = min(max(bottomFadeStart / height, topOpaque), 1)
        let bottomClear = min(max(footerTop / height, bottomOpaque), 1)

        return [
            .init(color: .clear, location: topClear),
            .init(color: .black, location: topOpaque),
            .init(color: .black, location: bottomOpaque),
            .init(color: .clear, location: bottomClear),
        ]
    }

    // MARK: 歌词提供者页脚

    /// 静态页脚，**完全不参与**卡拉OK / 焦点 / 模糊那套。
    ///
    /// 参数是刻意定的，别照搬歌词行的取值：
    ///   · 字号 13pt —— 比正文小两级，明确是元信息而不是内容
    ///   · 不透明度 0.35 —— 要**高于**非焦点行的 0.175（否则它会沉进底噪里读不出来），
    ///     又要**明显低于**已唱词的 1.0（否则它会比没唱到的歌词还亮，像多出来的标题）
    ///   · 左对齐 —— 和歌词一致；居中的页脚会读成标题
    ///   · 上间距 24pt —— 和正文拉开，形成独立的"页脚区"
    private var providerFooter: some View {
        Text("word_by_word_lyrics_provider".localizeWithFormat(provider))
            .font(.system(size: 13))
            .foregroundStyle(primaryColor.opacity(0.35))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 24)
    }

    // MARK: 点行跳转

    /// 点击某一行：seek 到它的时间，并**立刻把它滚到视口中间**。
    ///
    /// 为什么要在这里直接滚，而不是等 `onChange(of: highlightedLyricID)`：
    ///   `onChange` 是唯一的滚动入口，而它被 `shouldAutoScroll()` 的两道闸门挡着
    ///   （用户滚动暂停窗口 + 自动滚动节流）。点击之后位置更新触发的 `onChange`
    ///   会被**节流挡掉**，表现就是"点了歌词停在原地、不回中间"。
    ///
    /// 所以点击走独立的滚动路径：
    ///   1. 清掉暂停窗口与节流（用户刚刚明确表达了"我要看这一行"）
    ///   2. 立刻把被点的这一行居中（不带动画，避免先看见一段位移）
    ///   3. 再执行 seek；若实际高亮落在别的行，`onChange` 会补一次动画滚动
    private func handleTap(on line: LyricLine, proxy: ScrollViewProxy) {
        autoScrollPauseUntil = .distantPast
        lastDragTime = .distantPast
        lastAutoScrollTime = .distantPast

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(line.id, anchor: .center)
        }

        onSeek?(line.time)
        // 关键：把节流起点留在"过去"，而不是设为 now。
        //
        // seek 是异步的：位置更新后 `onChange(of: highlightedLyricID)` 才会触发。
        // 如果这里把 lastAutoScrollTime 设为 now，那次 onChange 会被 0.35s 节流挡掉，
        // 于是"点了不回中间"。留成 distantPast 是让紧接着的那次补滚动**一定**放行 ——
        // 它最多再滚一次（目标就是刚点的这一行），是幂等的。
        lastAutoScrollTime = .distantPast
    }

    // MARK: 单行

    @ViewBuilder
    private func row(
        for line: LyricLine,
        position: LyricPlaybackPosition,
        availableWidth: CGFloat,
        proxy: ScrollViewProxy
    ) -> some View {
        let isFocused = position.highlightedLyricID == line.id
        let isActive = position.activeLyricIDs.contains(line.id)
        let focusStrength = focusStrength(
            isFocused: isFocused,
            isActive: isActive
        )

        SynchronizedLyricText(
            syllables: line.syllables,
            text: line.text,
            playbackTime: playbackTime,
            isFocused: isFocused,
            focusStrength: focusStrength,
            translation: line.translation,
            backgroundVocal: line.backgroundVocal,
            // 显式传真实宽度，不要再依赖 SwiftUI 推断（那正是文字溢出的原因）。
            constrainedWidth: availableWidth,
            alignment: .leading,
            typography: typography,
            primaryColor: primaryColor,
            appliesTimingEffects: isActive,
            showsBackgroundVocals: showsBackgroundVocals,
            showsTranslation: showsTranslation
        )
        // 注：这里曾经有一个 `.frame(width: availableWidth, alignment: .leading)`。
        // 它是我为了"让 SwiftUI 与折行构建器用同一个宽度"加的，**MeloX 没有这个**。
        // 宽度已经通过 `constrainedWidth` 传给构建器与渲染器，再由
        // `SynchronizedLyricText` 内部的 `.frame(maxWidth: .infinity)` 约束 —— 
        // 多出来的这一层硬宽度反而让 SwiftUI 与构建器各算一次折行。
        // 焦点态：缩放 + 透明度 + 模糊。三者都跟随 focusStrength，所以
        // 行切换时是同一条曲线，不会各走各的。
        .scaleEffect(
            CGFloat(
                Self.profile.deselectedScale
                    + (1 - Self.profile.deselectedScale) * focusStrength
            ),
            anchor: .leading
        )
        .opacity(
            Self.profile.deselectedTextOpacity
                + (Self.profile.selectedTextOpacity
                    - Self.profile.deselectedTextOpacity) * focusStrength
        )
        .blur(radius: blurRadius(focusStrength: focusStrength))
        .contentShape(Rectangle())
        .onTapGesture {
            handleTap(on: line, proxy: proxy)
        }
        .animation(
            .spring(duration: 0.45, bounce: 0.05, blendDuration: 0),
            value: isFocused
        )
    }

    /// 焦点强度：焦点行 1；正在唱但不是焦点（对唱/重叠）0.7；其余 0。
    private func focusStrength(isFocused: Bool, isActive: Bool) -> Double {
        if isFocused { return 1 }
        return isActive ? 0.7 : 0
    }

    /// 非焦点行的模糊：跟随焦点强度，离焦点越"远"越糊（这里只做线性过渡）。
    private func blurRadius(focusStrength: Double) -> CGFloat {
        let radius = Self.profile.nonFocusedBlurRadius
            + (Self.profile.maximumNonFocusedBlurRadius
                - Self.profile.nonFocusedBlurRadius)
        return CGFloat(radius * (1 - min(max(focusStrength, 0), 1)))
    }

    // MARK: 关闭按钮

    private func closeButton(_ action: @escaping () -> Void) -> some View {
        VStack {
            HStack {
                Spacer()
                Button(action: action) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(12)
                        .background(
                            Circle().fill(Color.white.opacity(0.14))
                        )
                }
                .padding(.top, 54)
                .padding(.trailing, 20)
            }
            Spacer()
        }
    }
}
