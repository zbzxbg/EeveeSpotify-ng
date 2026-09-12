import Orion
import UIKit

// Orion 的 `Ivars` / `ClassHook` 都来自这里。`Ivars` 在本文件里已不再使用 ——
// 读 `headerView` 改用 KVC（理由见 `fullscreenChromeCandidates`），
// 但 `import Orion` 保留：本目录其它文件与本模块的 hook 体系都依赖它。

// ── 关于 main-actor 隔离：一个踩过的坑 ────────────────────────────────────
//
// ⚠️ **不要在 Orion 的 hook 方法（覆写的那几个）上写 `@MainActor`。**
//
// Orion 会把 hook 类里的方法改写成 `override` + 一段 C 跳板，而它的代码生成器
// 是**按源码文本拼接**的：`@MainActor` 会被拼成 `@MainActoroverride`（非法属性），
// 连带 `override` 关键字一起丢掉，最后生成出一堆语法错误，
// 并且生成的跳板是**非隔离**的，同步调用被标成 `@MainActor` 的方法又成了隔离违规。
//
// 正确做法：hook 方法保持非隔离（Orion 生成什么就是什么），在方法体里用
// `onMainThreadSync { ... }` 把主线程这件事显式表达出来。见下面这个 helper。
//
// ── 顺带说清"谁是主线程"─────────────────────────────────────────────────
// UIKit 的生命周期回调（viewDidAppear / viewWillDisappear）本来就在主线程，
// 所以 `assumeIsolated` 不会失败；万一哪天不是，helper 会退回 async 派发，
// 而不是崩。

/// 在 main actor 上**同步**执行一段代码。
///
/// 用于 Orion 的 hook 方法体里：那些方法在编译期是"非隔离"的，不能直接碰
/// `@MainActor` 的类型（例如 `WordByWordHost`、`LyricsChromeVisibilityController`）。
/// 已经是主线程时立即执行（不改变时序，`viewWillDisappear` 里的清理必须是同步的）；
/// 万一不是，则异步派发到主线程。
func onMainThreadSync(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
        }
    }
}

// 全屏歌词页：**停留一会儿就把 Spotify 自己的界面淡掉**（沉浸模式）。
//
// ── 为什么只调 alpha，而不是"自己出壳" ────────────────────────────────────
// 这一页的原生结构极其脆弱：全屏页根视图里**一个子视图都没有**（dump 实测），
// header / 歌词 / 控件栏都不在那一层。之前试过的所有"接管"手段
// （隐藏歌词容器、清根视图底色、把整层插到最底）都直接把整页弄空白了。
//
// 所以这里换一条完全不同的路：**不替换、不重建、不碰约束**，
// 只把原生那两块容器的 `alpha` 淡到 0。Spotify 的控件全部保持原样 ——
// 能点、能用、坐标不变，只是在"该沉浸的时候"看不见。
//
// ── 交互规则（读法 A）────────────────────────────────────────────────────
//   · 任何触摸/拖动/点击 → 立刻唤回界面，并重新开始计时
//   · 停止交互 3 秒后 → 淡出
//   · 拖动歌词期间**绝不**隐藏（每次 onChanged 都会推进截止时间）
//
// 取不到容器时整条链路静默降级：界面永远可见，不会出现"半隐藏"的破损状态。
//
// `@MainActor`：这一类只碰 UIKit，而调用点（宿主挂载、SwiftUI 手势、卸载）本来
// 都在主线程 —— 显式标出来，避免以后有人在后台线程调用它。

@MainActor
final class LyricsChromeVisibilityController {

    static let shared = LyricsChromeVisibilityController()

    /// 停手之后多久淡出。
    static let hideDelay: TimeInterval = 3

    /// 淡出 / 唤回的时长。唤回比淡出快一点：需要看的时候要立刻看到。
    private let fadeOutDuration: TimeInterval = 0.25
    private let fadeInDuration: TimeInterval = 0.15

    /// 被我们改过 alpha 的视图 → 原值。卸载时原样还回。
    private var originals: [UIView: CGFloat] = [:]
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    /// 记录"这一页的界面由哪几个容器组成"，并立刻显示出来。
    ///
    /// - Parameter views: 需要淡入淡出的原生容器（header / 控件栏所在的盒子）。
    func adopt(_ views: [UIView]) {
        // 同一批容器重复 adopt（每次重新挂载都会调到这里）：
        // 只把界面唤回来 + 重置计时，**不要**清表重来 —— 那会把"当前正淡出到 0.4"
        // 的状态重置成"重新采集成 1.0"，界面每挂一次就闪一下。
        if !originals.isEmpty,
           Set(originals.keys.map(ObjectIdentifier.init))
               == Set(views.map(ObjectIdentifier.init)) {
            show()
            scheduleHide()
            return
        }

        restore()
        for view in views where originals[view] == nil {
            originals[view] = view.alpha
        }
        setAlpha(1, duration: 0)
        writeDebugLog(
            "[ChromeVisibility] adopted \(originals.count) container(s): "
                + originals.keys.map { NSStringFromClass(type(of: $0)) }.joined(separator: ",")
        )
        scheduleHide()
    }

    /// 用户碰了屏幕（拖动、点击、滚动）→ 立刻唤回，并重新计时。
    func noteUserInteraction() {
        guard !originals.isEmpty else { return }
        show()
        scheduleHide()
    }

    /// 立刻显示界面（用于重新挂载、关闭全屏等需要"恢复常态"的时刻）。
    func show() {
        guard !originals.isEmpty else { return }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        setAlpha(1, duration: fadeInDuration)
    }

    /// 卸载：取消计时并把 alpha 还给 Spotify。
    func restore() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard !originals.isEmpty else { return }
        for (view, alpha) in originals {
            view.alpha = alpha
        }
        originals.removeAll()
    }

    // MARK: 内部

    /// 延时淡出。重复调用会**重置**计时（拖动中的每帧都走这里，等于一直续期）。
    private func scheduleHide() {
        hideWorkItem?.cancel()
        guard !originals.isEmpty else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setAlpha(0, duration: self.fadeOutDuration)
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: item)
    }

    private func setAlpha(_ alpha: CGFloat, duration: TimeInterval) {
        // 已经到位就不做无谓的动画（拖动时每帧都会调到这里）。
        let pending = originals.filter { abs($0.value - alpha) > 0.001 }
        guard !pending.isEmpty else { return }

        let apply = {
            for (view, _) in pending {
                view.alpha = alpha
            }
        }

        guard duration > 0 else {
            apply()
            return
        }

        // 视图不在 window 上时不去动画（那只会白白等一个不会发生的过渡）。
        guard originals.keys.contains(where: { $0.window != nil }) else {
            apply()
            return
        }

        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: apply
        )
    }
}

// MARK: - 找到"界面"到底是哪几块视图

/// `@MainActor`：这几个方法只读 UIKit 视图层次，调用点（宿主挂载）也在主线程。
@MainActor
extension UIViewController {

    /// 全屏歌词页里需要淡出的原生容器。
    ///
    /// 两条线索，都是**这个项目里已经在用**的：
    ///   1. `vc.view` 的 `headerView` ivar —— 标题 / 歌手 / 关闭按钮
    ///      （`CustomLyrics+DisableReportButton.x.swift` 与旧 overlay 都这么取）
    ///   2. 从 `Lyrics_FullscreenElementPageImpl.LyricsView` **往上找到根视图之前的那一层**
    ///      —— 那一层同时装着歌词和控件栏，是天然的"界面盒子"。
    ///      用"往上找"而不是"按 FullscreenView 类名找"，是因为类名会变，而
    ///      "歌词内容的父级"这个关系不会变。
    ///
    /// - Parameter lyricsContent: `Lyrics_FullscreenElementPageImpl.LyricsView`，
    ///   取不到时返回空数组（调用方静默降级）。
    func fullscreenChromeCandidates(lyricsContent: UIView?) -> [UIView] {
        // ⚠️ `UIViewController.view` 在 Swift 里是 `UIView!`（隐式解包可选），
        // 而 `Ivars<T>` 要的是非可选的类实例 —— 不先解包就是
        // "把 UIView? 传给要求类类型约束的 Ivars<T>"。VC 没加载视图时直接放弃。
        guard let root = view else {
            writeDebugLog("[ChromeVisibility] ⚠️ view not loaded — auto-hide disabled")
            return []
        }

        var candidates: [UIView] = []

        // 用 KVC 而不是 `Ivars<UIView>(root).headerView`，就为了拿到 nil 的可能：
        // `Ivars` 生成的访问器把 ivar 当**非可选**返回，ivar 一旦不存在就是崩；
        // 而这条链路本来就允许"找不到就不启用"（静默降级）。
        // 先 `responds(to:)` 挡一道，KVC 取不到也不会抛 NSUndefinedKeyException。
        let headerSelector = NSSelectorFromString("headerView")
        if root.responds(to: headerSelector),
           let header = root.value(forKey: "headerView") as? UIView {
            candidates.append(header)
        }

        if let lyricsContent, lyricsContent !== root {
            var node = lyricsContent
            // 走到"父视图就是根视图"为止：node 就是根视图下那一层盒子。
            while let parent = node.superview, parent !== root {
                node = parent
            }
            if node !== root, !candidates.contains(where: { $0 === node }) {
                candidates.append(node)
            }
        }

        if candidates.isEmpty {
            writeDebugLog("[ChromeVisibility] ⚠️ no chrome container found — auto-hide disabled")
        }
        return candidates
    }
}
