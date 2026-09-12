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
    /// 歌词提供者（形如 `"AMLL TTML (EeveeSpotify)"`）。为空则不显示页脚。
    let provider: String
    /// 是否显示歌词提供者页脚。内嵌预览容器太小，不显示。
    let showsProviderFooter: Bool

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
        showsProviderFooter: Bool = false
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

    /// 顶部淡出结束位置（视口高度比例）—— 取自 MeloX 的 `topOpaque: 0.08`。
    private var fadeTopRatio: CGFloat { 0.08 }
    /// 底部开始淡出的位置。MeloX 用 0.84；全屏时下方还有控件栏要避让，
    /// 所以按是否有页脚留白略微提前。
    private var fadeBottomOpaqueRatio: CGFloat {
        showsProviderFooter ? 0.80 : 0.86
    }

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
                        .padding(.top, contentInsets.top)
                        .padding(.bottom, contentInsets.bottom)
                        .padding(.horizontal, contentInsets.leading)
                    }
                    // ⚠️ 进入时必须**无条件**定位一次。
                    //
                    // `onChange` 只在值**变化**时触发：首次渲染时当前行已经就是高亮行，
                    // 所以它永远不会为"初始这一行"跑一次 —— 结果全屏打开、或从预览切回全屏
                    // 时，歌词停在最顶上而不是当前行。
                    // 旧 overlay 没这个问题：它首帧 `activeLineIndex = -1`，
                    // 必然走一次 `scrollToLine`。
                    .onAppear {
                        guard let id = position.highlightedLyricID else { return }
                        // 延后一帧再滚：`LazyVStack` 是先物化可见区域再响应 scrollTo 的，
                        // 在 onAppear 里立刻调用时目标行往往还没生成，会静默失效。
                        // 延后一帧仍然是不带动画的落位。
                        Task { @MainActor in
                            proxy.scrollTo(id, anchor: .center)
                            lastAutoScrollTime = Date()
                        }
                    }
                    .onChange(of: position.highlightedLyricID) { _, newValue in
                        guard let newValue else { return }
                        guard shouldAutoScroll() else { return }
                        lastAutoScrollTime = Date()
                        withAnimation(
                            .spring(
                                duration: 0.5,
                                bounce: 0.08,
                                blendDuration: 0
                            )
                        ) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                    // 滚动打断保护：用户一碰就暂停自动跟随。
                    //
                    // SwiftUI 的 DragGesture 只有 onChanged/onEnded，拿不到
                    // UIScrollView 那套 willBeginDragging / didEndDecelerating，
                    // 所以用"最后一次拖动时间 + 固定窗口"近似覆盖惯性滚动阶段。
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { _ in
                                lastDragTime = Date()
                                autoScrollPauseUntil = Date()
                                    .addingTimeInterval(postDragPauseDuration)
                            }
                            .onEnded { _ in
                                lastDragTime = Date()
                                autoScrollPauseUntil = Date()
                                    .addingTimeInterval(postDragPauseDuration)
                            }
                    )
                    // 上下边缘淡出。
                    //
                    // 这是旧 overlay 有、而我移植时漏掉的一块（它用两个
                    // `topFadeView` / `bottomFadeView` 渐变层实现）。
                    // 这里改用 MeloX 的做法：**遮罩歌词内容本身**，背景不参与 ——
                    // 这样不会出现"背景渐变换色 + 内容渐变"两层叠加变脏的问题。
                    //
                    // 比例取自 MeloX 的 `lyricsMaskLocations`：
                    //   顶部 · 底部完全不透明 · 底部开始淡出位置
                    //   0.08 · 0.84 · 1.0
                    // 全屏模式下底部留白更多（要给控件栏让位），所以淡出起点略提前。
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: fadeTopRatio),
                                .init(
                                    color: .black,
                                    location: fadeBottomOpaqueRatio
                                ),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                if let onClose {
                    closeButton(onClose)
                }
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
