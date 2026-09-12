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
    /// 当前是不是"铺在整屏最底层"的挂法。挂法变了要重挂（见 `update`）。
    private var currentMountsAtBottom: Bool = false

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
    ///   - mountsAtBottom: 是否把整层插到**最底层**并清掉宿主自己的底色。
    ///
    ///     ⚠️ 这个参数回答的是"为什么背景铺满屏了、屏幕上还是有品红壳"。
    ///
    ///     全屏页的层次大致是：
    ///       vc.view
    ///         ├─ Lyrics_FullscreenElementPageImpl.LyricsView（歌词内容 + 自己的暗化底）
    ///         └─ Lyrics_FullscreenElementPageImpl.FullscreenView
    ///              ├─ header（标题/歌手/关闭）
    ///              ├─ controlsView（分享 / 更多 / 进度条 / 播放键）
    ///              └─ lyrics 内容（同一个 LyricsView 的引用，或是它的兄弟）
    ///     品红壳属于**外层**（vc.view 或 FullscreenView），不在歌词容器里。
    ///     所以"把 overlay 挂到根视图"只解决了尺寸，没解决**谁盖住谁**：
    ///     外层的漆不是我们能"盖"掉的，得让它的底不存在（清掉）或让它整体挪到我们下面。
    ///
    ///     具体清哪一层由挂载时 dump 出的视图树决定（`dumpFullscreenHierarchy`）——
    ///     壳的类名在各版本里不保证一致，猜不如看。
    func update(
        in view: UIView,
        sideInset: CGFloat,
        showsProviderFooter: Bool,
        mountsAtBottom: Bool = false
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

        // 宿主没变时**就地更新**，不重建 hosting controller。
        //
        // 之前这里重建 rootView：代价是整页 SwiftUI 状态（滚动位置）被丢掉，
        // 于是全屏 ↔ 预览切换后歌词回到顶部、不再居中于当前行。
        // 改成 var 属性写入后，SwiftUI 只重新计算布局，页面身份与滚动位置都保留。
        let insetChanged = sideInset != currentSideInset
        let footerChanged = showsProviderFooter != currentShowsProviderFooter
        // 挂法变了（内嵌 ↔ 全屏会把同一块宿主换成 vc.view）→ 需要**搬**视图，
        // 但依然不重建：`removeFromSuperview` + `addSubview` 会把子视图和约束一起带走，
        // SwiftUI 的页面身份与滚动位置都留着。
        let mountChanged = mountsAtBottom != currentMountsAtBottom
        let hostChanged = hostingController?.view.superview !== view

        if let hostingController, !mountChanged, !hostChanged {
            currentSideInset = sideInset
            currentShowsProviderFooter = showsProviderFooter

            if insetChanged || footerChanged {
                hostingController.rootView.sideInset = sideInset
                hostingController.rootView.showsProviderFooter = showsProviderFooter
            }
            return
        }

        let hosting: UIHostingController<AppleMusicLyricsOverlayView>
        if let existing = hostingController, !hostChanged {
            hosting = existing
        } else {
            detach()
            hosting = UIHostingController(
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
        }

        // 换挂载点（内嵌的歌词容器 → 全屏页根视图）时先还原**上一个**宿主的底色，
        // 再清当前这个 —— 保证任何时刻最多只有一块宿主被清过。
        if let previous = hostView, previous !== view {
            restoreHostBackground()
        }

        currentSideInset = sideInset
        currentShowsProviderFooter = showsProviderFooter
        currentMountsAtBottom = mountsAtBottom

        hosting.view.removeFromSuperview()

        // 全屏：先把宿主自己刷的那层"壳漆"清掉，再插到最底层。
        // 顺序是刻意的 —— 清漆必须在插入之前，否则中间那一帧是「我们盖着品红」。
        if mountsAtBottom {
            stripHostBackground(of: view)
        }

        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        if mountsAtBottom {
            // 插到最底：header / 控件栏 / 歌词容器全都从我们上方经过，
            // 它们本身没有不透明底（底是宿主刷的、刚被清掉），于是整屏都是我们的背景。
            view.sendSubviewToBack(hosting.view)
            dumpFullscreenHierarchy(hosting: hosting.view, in: view)
            // 再 dump 一次：present 动画期间 Spotify 才会把壳的视图装齐，
            // `viewDidAppear` 那一刻看到的树并不完整。
            scheduleFullscreenSecondPass(for: view)
        }

        hostingController = hosting
        hostView = view
        writeDebugLog(
            "[AppleMusicLyrics] overlay attached (Apple Music path)"
                + " host=\(NSStringFromClass(type(of: view)))"
                + " mountsAtBottom=\(mountsAtBottom)"
        )
    }

    func detach() {
        // ⚠️ 还原宿主背景**不能**用 `guard hostingController != nil` 挡住：
        // 走到这里可能已经没有任何 hosting controller，却仍然清着某个宿主的底色
        // （例如全屏页被系统直接销毁、没走我们的 detach）。还原操作本身是幂等的
        // ——两张表空了就什么都不做。
        if hostingController != nil {
            hostingController?.view.removeFromSuperview()
            hostingController = nil
            hostView = nil
        }
        // 把宿主那层漆还回去。**必须还原** —— 它是 Spotify 自己的视图，
        // 我们只是借用期间清掉；不还原的话离开全屏后那段页面会失去底色。
        restoreHostBackground()
        currentMountsAtBottom = false
        writeDebugLog("[AppleMusicLyrics] overlay detached")
    }

    // MARK: 宿主底色的清除与还原

    /// 宿主根视图上被我们摘掉的层，以及它原来的背景色。`detach` 时原样还回。
    ///
    /// 用一个 `NSMapTable`（weak → strong）而不是字典：宿主一旦被销毁，
    /// 我们不该再持有它的 layer 或视图。
    private var strippedLayers = NSMapTable<UIView, NSMutableArray>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )
    /// 被我们清掉 backgroundColor 的视图及其原色。
    private var clearedBaseColors = NSMapTable<UIView, UIColor>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    /// 清掉宿主「自己刷的漆」，让我们的背景成为唯一底色。
    ///
    /// 只处理宿主**自己**的两类东西，别的一律不碰：
    ///   · `backgroundColor` —— 根视图自己刷的品红
    ///   · `layer` 上的 `CAGradientLayer` / 纯色 `CALayer` —— Spotify 的暗化渐变
    ///
    /// ⚠️ 这里**刻意不去动子视图**。第一版我顺手把"铺满整屏的直接子视图"的底色也清了，
    /// 那是错的：根视图的直接子视图里就有一个 `FullscreenView`，它自带底漆**就是为了
    /// 盖住我们的背景**；把它的底色清掉，还没等我们理清层次，下一层的底漆又露出来 ——
    /// 会变成"清了一层又冒一层"的打地鼠。正确顺序是先用 dump 看清是哪一层，
    /// 再把那一层整体挪到我们下面（而不是把它刷的漆刮掉）。
    ///
    /// 形状层、遮罩层、`CAReplicatorLayer` 之类同样保留：那些多半承担布局或内容。
    private func stripHostBackground(of view: UIView) {
        if let rootColor = view.backgroundColor, !isClear(rootColor) {
            clearedBaseColors.setObject(rootColor, forKey: view)
            view.backgroundColor = .clear
            writeDebugLog(
                "[AppleMusicLyrics] cleared root background \(describe(rootColor))"
            )
        }

        // ⚠️ 这里用类名比较而不是 `$0 is CALayer` / `type(of:) == CALayer.self`：
        // `CAGradientLayer` 是 `CALayer` 的子类，`is` 会把它一起匹配进来（那没问题），
        // 但 `type(of: $0) == CALayer.self` 在 Swift 里是编译不过的写法（元类型比较
        // 需要同一静态类型）。类名字符串最省事，也方便日志里直接看。
        let strippable = view.layer.sublayers?.filter {
            $0 is CAGradientLayer || NSStringFromClass(type(of: $0)) == "CALayer"
        } ?? []
        guard !strippable.isEmpty else { return }

        let store = strippedLayers.object(forKey: view) ?? NSMutableArray()
        for layer in strippable {
            store.add(layer)
            layer.removeFromSuperlayer()
        }
        strippedLayers.setObject(store, forKey: view)
        writeDebugLog(
            "[AppleMusicLyrics] stripped \(strippable.count) background layer(s): "
                + strippable.map { NSStringFromClass(type(of: $0)) }.joined(separator: ",")
        )
    }

    private func restoreHostBackground() {
        for view in allKeys(of: strippedLayers) {
            guard let store = strippedLayers.object(forKey: view) else { continue }
            for case let layer as CALayer in store {
                // 插到最底：它原本就是我们摘掉的那层底漆。
                view.layer.insertSublayer(layer, at: 0)
            }
        }
        strippedLayers.removeAllObjects()

        for view in allKeys(of: clearedBaseColors) {
            view.backgroundColor = clearedBaseColors.object(forKey: view)
        }
        clearedBaseColors.removeAllObjects()
    }

    private func allKeys(of table: NSMapTable<UIView, NSMutableArray>) -> [UIView] {
        var keys: [UIView] = []
        for case let key as UIView in table.keyEnumerator() {
            keys.append(key)
        }
        return keys
    }

    private func allKeys(of table: NSMapTable<UIView, UIColor>) -> [UIView] {
        var keys: [UIView] = []
        for case let key as UIView in table.keyEnumerator() {
            keys.append(key)
        }
        return keys
    }

    private func isClear(_ color: UIColor) -> Bool {
        var alpha: CGFloat = 0
        guard color.getRed(nil, green: nil, blue: nil, alpha: &alpha) else { return false }
        return alpha <= 0.001
    }

    private func describe(_ color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "\(color)"
        }
        return String(
            format: "rgba(%.3f,%.3f,%.3f,%.3f)",
            red, green, blue, alpha
        )
    }

    // MARK: 诊断

    /// 挂载后延时再 dump 一次视图树。
    ///
    /// 为什么需要第二次：全屏页是 **sheet**，`viewDidAppear` 时 present 动画还没结束，
    /// Spotify 往往在动画期间才把 header / 控件栏这些壳的视图装齐。
    /// 第一次 dump 看到的树可能是不完整的。
    private func scheduleFullscreenSecondPass(for view: UIView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak view] in
            guard let self, let view else { return }
            guard let hosting = self.hostingController?.view,
                  hosting.superview === view else { return }
            writeDebugLog("[AppleMusicLyrics] fullscreen second pass")
            view.sendSubviewToBack(hosting)
            self.dumpFullscreenHierarchy(hosting: hosting, in: view)
        }
    }

    /// 全屏页的视图树诊断（递归，最多 `maxDepth` 层）。
    ///
    /// 只在设置里开着「开启日志记录」时输出。
    /// 用途：确认「壳」（品红底 + header + 控件栏）到底是**哪一层**视图刷的色。
    /// 只有看清层次，才能决定把哪一层挪到我们下面 —— 盲清底色会变成打地鼠。
    ///
    /// 输出顺序与 `subviews` 一致 = **从后往前**，所以要盖住谁、谁在我上面，
    /// 直接看序号就行。
    private func dumpFullscreenHierarchy(
        hosting: UIView,
        in root: UIView,
        maxDepth: Int = 4
    ) {
        writeDebugLog("[AppleMusicLyrics] ---- fullscreen view tree ----")
        // 顺带报一下宿主父视图：全屏页是 sheet，真正刷壳色的可能是外面那层容器。
        if let superview = root.superview {
            writeDebugLog(
                "[AppleMusicLyrics] superview=\(NSStringFromClass(type(of: superview)))"
                    + " \(rectDescription(superview.frame))"
                    + " bg=\(superview.backgroundColor.map(describe) ?? "nil")"
            )
        }

        func line(for view: UIView, depth: Int, index: Int) -> String {
            let indent = String(repeating: "  ", count: depth)
            let relation = view === hosting ? " <- backdrop" : ""
            return "[AppleMusicLyrics] \(indent)[\(index)] "
                + NSStringFromClass(type(of: view))
                + " \(rectDescription(view.frame))"
                + " bg=\(view.backgroundColor.map(describe) ?? "nil")"
                + " cicolor=\(cicolorDescription(view))"
                + " alpha=\(String(format: "%.2f", view.alpha))"
                + " hidden=\(view.isHidden)"
                + " layers=\(layerSummary(view.layer))\(relation)"
        }

        func walk(_ view: UIView, depth: Int) {
            for (index, subview) in view.subviews.enumerated() {
                writeDebugLog(line(for: subview, depth: depth, index: index))
                if depth < maxDepth, !subview.subviews.isEmpty {
                    walk(subview, depth: depth + 1)
                }
            }
        }

        writeDebugLog(line(for: root, depth: 0, index: 0))
        walk(root, depth: 1)
        writeDebugLog("[AppleMusicLyrics] ---- end view tree ----")
    }

    private func layerSummary(_ layer: CALayer) -> String {
        let names = (layer.sublayers ?? []).map { NSStringFromClass(type(of: $0)) }
        return names.isEmpty ? "-" : names.joined(separator: ",")
    }

    /// 视图 layer 上 `contents` 的对象类型（如果有）。
    ///
    /// Spotify 的底色有时根本不走 `backgroundColor`，而是设 `backgroundImage` /
    /// 直接把一张 `CIImage` 铺在 layer 的 `contents` 上 —— 那样 `bg=nil` 却有色块。
    /// 这一栏就是为了不漏掉那种情况（`CIImage` 说明该层是用图片画的底）。
    private func cicolorDescription(_ view: UIView) -> String {
        guard let contents = view.layer.contents else { return "-" }
        return String(describing: type(of: contents))
    }

    private func rectDescription(_ rect: CGRect) -> String {
        String(
            format: "(%.0f,%.0f %.0fx%.0f)",
            rect.origin.x, rect.origin.y, rect.width, rect.height
        )
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
