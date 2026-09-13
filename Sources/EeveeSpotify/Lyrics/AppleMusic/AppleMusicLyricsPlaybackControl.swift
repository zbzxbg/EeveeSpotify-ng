import Foundation
import SwiftUI
import UIKit

// 自绘"壳"的**动作层**：播放 / 暂停 / 上下曲。
//
// ── 为什么是"探测"而不是"直接调" ──────────────────────────────────────────
// 本模块所有 hook 都靠 runtime 探测（`responds(to:)` + `Dynamic.convert`），
// 因为 Spotify 的私有类名与协议不对外承诺。自己出壳之后我们需要三个原生没有的
// 动作：toggle 播放/暂停、下一曲、上一曲。做法与 `WordByWordSeeker` 完全一致：
//   1. 先看 `statefulPlayer` 自己有没有这个方法；
//   2. 再在**界面层级里**找那个按钮（Spotify 的播放键是 UIControl，且在无障碍
//      树里有稳定的标签："Pause"/"暂停"、"Next"/"下一首"…）；
//   3. 都没有就什么都不做（按钮仍然可点，只是没反应，不崩、不错乱）。
//
// ── 为什么"找按钮"这条并不脏 ──────────────────────────────────────────────
// 自己出壳是**视觉上**接管：原生那一页仍然完整存在（我们只是把它盖住），
// 它的播放键依旧连着真实的播放管线。所以"找到那个按钮并发一个 touchUpInside"
// 比自己去拼 `play()`/`pause()` 这种未公开签名**更可靠** —— 不依赖任何私有方法名，
// 只依赖一个无障碍标签，而那个标签是 Spotify 为 VoiceOver 维护的、不会乱改。

enum WordByWordPlaybackControl {

    // MARK: 播放 / 暂停

    /// 切换播放 / 暂停。
    /// 先试 `statefulPlayer` 上的方法，再退回"点原生播放键"。
    @discardableResult
    static func togglePlayPause() -> Bool {
        if let player = statefulPlayer as? NSObject {
            for name in ["togglePlayPause", "playPause", "togglePlayback"] {
                let selector = Selector(name)
                guard player.responds(to: selector) else { continue }
                writeDebugLog("[Shell] togglePlayPause via statefulPlayer.\(name)()")
                player.perform(selector)
                return true
            }
        }

        if let button = findTransportButton(
            labels: playPauseLabels,
            excluding: playPauseExclusions,
            exactMatch: true
        ) {
            writeDebugLog("[Shell] togglePlayPause via native button")
            sendTap(to: button)
            return true
        }

        writeDebugLog("[Shell] ⚠️ togglePlayPause unavailable — no method, no button")
        return false
    }

    // MARK: 切歌

    @discardableResult
    static func skipToNext() -> Bool {
        if let player = statefulPlayer as? NSObject {
            for name in ["skipToNext", "next", "skipToNextTrack"] {
                let selector = Selector(name)
                guard player.responds(to: selector) else { continue }
                writeDebugLog("[Shell] skipToNext via statefulPlayer.\(name)()")
                player.perform(selector)
                return true
            }
        }

        if let button = findTransportButton(labels: nextLabels, excluding: playPauseExclusions) {
            writeDebugLog("[Shell] skipToNext via native button")
            sendTap(to: button)
            return true
        }

        writeDebugLog("[Shell] ⚠️ skipToNext unavailable")
        return false
    }

    /// 已播超过该秒数时，「上一首」先回到本曲开头（与 Spotify 原生一致）。
    private static let previousRestartThreshold: Double = 5.0

    @discardableResult
    static func skipToPrevious() -> Bool {
        // 标准语义：已播 ≥5s → 回本曲开头；不足 5s → 才切上一首。
        // 位置读不到（nil）时直接落到原有逻辑，不影响可用性。
        if let position = WordByWordPositionResolver.shared.currentPositionSeconds(),
           position >= previousRestartThreshold {
            writeDebugLog("[Shell] skipToPrevious -> restart current track (pos=\(position)s)")
            WordByWordSeeker.seek(toMs: 0)
            return true
        }

        if let player = statefulPlayer as? NSObject {
            for name in ["skipToPrevious", "previous", "skipToPreviousTrack"] {
                let selector = Selector(name)
                guard player.responds(to: selector) else { continue }
                writeDebugLog("[Shell] skipToPrevious via statefulPlayer.\(name)()")
                player.perform(selector)
                return true
            }
        }

        if let button = findTransportButton(labels: previousLabels, excluding: playPauseExclusions) {
            writeDebugLog("[Shell] skipToPrevious via native button")
            sendTap(to: button)
            return true
        }

        writeDebugLog("[Shell] ⚠️ skipToPrevious unavailable")
        return false
    }

    // MARK: 预览卡片：展开 / 分享

    /// 展开到全屏歌词页。
    ///
    /// 「自己出壳」之后卡片上那个小箭头被我们盖住了，但**功能还在** ——
    /// 优先按无障碍 id 找（`lyrics-expand-button`，真机 dump 确认存在），
    /// 找不到才退回按标签猜。
    @discardableResult
    static func expandToFullscreenLyrics() -> Bool {
        if tapControl(withIdentifier: "lyrics-expand-button", action: "expand lyrics") {
            return true
        }
        return tapNativeControl(
            labels: ["expand", "full screen", "fullscreen", "展开", "全屏", "放大"],
            action: "expand lyrics"
        )
    }

    /// 分享歌词。同样优先按 id（`lyrics-share-button`）。
    @discardableResult
    static func shareLyrics() -> Bool {
        if tapControl(withIdentifier: "lyrics-share-button", action: "share lyrics") {
            return true
        }
        return tapNativeControl(
            labels: ["share", "分享"],
            action: "share lyrics"
        )
    }

    /// 诊断：把"展开 / 分享"的**全部候选**连标签和 frame 打出来。
    ///
    /// 用途：真机上出现"点我们画的小方框没反应、点 `歌词` 两个字反而能进全屏"，
    /// 那说明我们找到的控件**不是卡片上那一颗**（很可能是页面别处同名按钮）。
    /// 这份 dump 把候选和它们的位置摊开，一眼就能看出该选哪一个 ——
    /// 之后按"在卡片范围内 / 离卡片最近"来挑即可，不用再猜。
    static func dumpPreviewActionCandidates() {
        guard let window = keyWindow else { return }
        dumpCandidates(
            title: "expand",
            labels: ["expand", "full screen", "fullscreen", "展开", "全屏", "放大"],
            in: window
        )
        dumpCandidates(title: "share", labels: ["share", "分享"], in: window)
    }

    private static func dumpCandidates(title: String, labels: [String], in window: UIWindow) {
        var matches: [UIControl] = []
        collectControls(
            in: window,
            labels: labels,
            excluding: [],
            exactMatch: false,
            into: &matches
        )
        writeDebugLog("[ShellDump] \(title) candidates: \(matches.count)")
        for control in matches.prefix(8) {
            let frame = control.convert(control.bounds, to: window)
            writeDebugLog(
                "[ShellDump]   \(title) \(kind(control))"
                    + " label=\"\(control.accessibilityLabel ?? "")\""
                    + " frame=(\(Int(frame.minX)),\(Int(frame.minY))"
                    + " \(Int(frame.width))x\(Int(frame.height)))"
            )
        }
    }

    // MARK: 通用：点一个原生控件

    /// 按**无障碍 id** 点一个原生控件。
    ///
    /// 比按标签找可靠得多 —— 标签是给 VoiceOver 看的、会随语言/文案变，
    /// 而 id 是开发定义的稳定标识。真机 dump 已确认这几颗都有 id：
    ///   · `lyrics-expand-button`  「将歌词界面扩展至全屏」
    ///   · `lyrics-share-button`   「分享歌词」
    ///   · `SPTNowPlayingNextTrackButton` / `SPTNowPlayingPreviousTrackButton`
    ///
    /// ⚠️ 为什么必须优先用 id：按标签全局找、取"面积最大"的做法**选错过**——
    /// 卡片上的"展开"和 Now Playing 页那颗同名按钮同时在窗口里，
    /// 结果选中了页面别处那颗（真机 dump：frame=(-36,692)；卡片那颗在 (334,360)），
    /// 于是"点我们画的方框没反应"。
    @discardableResult
    static func tapControl(withIdentifier identifier: String, action: String) -> Bool {
        guard let window = keyWindow else { return false }
        var matches: [UIControl] = []
        collectControls(byIdentifier: identifier, in: window, into: &matches)
        guard let control = matches.first else {
            writeDebugLog("[Shell] ⚠️ \(action) unavailable — id \"\(identifier)\" not found")
            return false
        }
        writeDebugLog(
            "[Shell] \(action) via id \"\(identifier)\""
                + " label=\"\(control.accessibilityLabel ?? "")\""
        )
        sendTap(to: control)
        return true
    }

    /// 按无障碍标签点一个原生控件（自绘壳替原生按钮转发动作时用）。
    ///
    /// ⚠️ 优先用 `tapControl(withIdentifier:action:)`：按标签找 + 取面积最大的策略
    /// 在真机上**选错过对象**（见那个方法的注释）。这个方法保留给"没有 id"的场景。
    ///
    /// - Parameters:
    ///   - labels: 标签候选（小写、`contains` 匹配）。
    ///   - excluding: 需要排除的词（例如找"播放"时要排掉"播放专辑"）。
    ///   - exact: true 时要求整体相等，用于 "close" 这类容易误伤的短词。
    ///   - action: 日志里显示的动作名。
    @discardableResult
    static func tapNativeControl(
        labels: [String],
        excluding: [String] = [],
        exact: Bool = false,
        action: String
    ) -> Bool {
        guard let control = findTransportButton(
            labels: labels,
            excluding: excluding,
            exactMatch: exact
        ) else {
            writeDebugLog("[Shell] ⚠️ \(action) unavailable — no matching control")
            return false
        }
        writeDebugLog(
            "[Shell] \(action) via native control"
                + " \(kind(control)) label=\"\(control.accessibilityLabel ?? "")\""
        )
        sendTap(to: control)
        return true
    }

    private static func collectControls(
        byIdentifier identifier: String,
        in view: UIView,
        into result: inout [UIControl]
    ) {
        if let control = view as? UIControl,
           isOnScreen(control),
           control.accessibilityIdentifier == identifier {
            result.append(control)
        }
        for subview in view.subviews {
            collectControls(byIdentifier: identifier, in: subview, into: &result)
        }
    }

    // MARK: 关闭全屏

    /// 关闭全屏歌词页。
    ///
    /// 优先点原生那个 chevron（走 Spotify 自己的返回逻辑，层级、动画、状态都由它
    /// 负责，比我们 `dismiss` 稳），找不到才退回 `dismiss(animated:)`。
    @discardableResult
    static func dismissFullscreen() -> Bool {
        if let button = findTransportButton(labels: closeLabels, exactMatch: true) {
            writeDebugLog("[Shell] dismiss via native close button")
            sendTap(to: button)
            return true
        }

        guard let root = keyWindow?.rootViewController else { return false }
        // 找到当前presented 的那一层：全屏歌词页是 sheet，最顶层就是它。
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        if top !== root {
            writeDebugLog("[Shell] dismiss via dismiss(animated:) on \(NSStringFromClass(type(of: top)))")
            top.dismiss(animated: true)
            return true
        }

        // 不是 present 出来的（push）→ 走导航栈返回。
        if let navigation = top.navigationController, navigation.viewControllers.count > 1 {
            writeDebugLog("[Shell] dismiss via popViewController")
            navigation.popViewController(animated: true)
            return true
        }

        writeDebugLog("[Shell] ⚠️ dismiss unavailable — no button, no presented VC, no nav stack")
        return false
    }

    // MARK: 诊断

    /// 把窗口里所有"可点的控件"连同它们的标签、位置打出来，并说明每个动作
    /// **会**选中哪一个。
    ///
    /// 用途：现在自绘壳的三键是靠"标签 + 面积最大"选目标的，真机上出现了
    /// "暂停键切去专辑""上一首没反应"这类现象 —— 那说明选错了控件。
    /// 光靠猜类名/标签改不动，必须看清那一刻窗口里到底有哪些控件、各自在哪。
    ///
    /// 只在「开启日志记录」打开时输出（`writeDebugLog` 自己受开关控制）。
    /// 在全屏壳挂载时调用一次。
    static func dumpControlCandidates() {
        guard let window = keyWindow else {
            writeDebugLog("[ShellDump] no key window")
            return
        }

        let screen = window.bounds
        writeDebugLog(
            "[ShellDump] ---- controls (window \(Int(screen.width))x\(Int(screen.height))) ----"
        )

        var found: [UIControl] = []
        collectAllControls(in: window, into: &found)

        guard !found.isEmpty else {
            writeDebugLog("[ShellDump] no on-screen UIControl at all")
            writeDebugLog("[ShellDump] ---- end ----")
            return
        }

        for control in found {
            let frame = control.convert(control.bounds, to: window)
            writeDebugLog(
                "[ShellDump] \(kind(control))"
                    + " label=\"\(control.accessibilityLabel ?? "")\""
                    + " id=\"\(control.accessibilityIdentifier ?? "")\""
                    + " title=\"\((control as? UIButton)?.title(for: .normal) ?? "")\""
                    + " frame=(\(Int(frame.minX)),\(Int(frame.minY))"
                    + " \(Int(frame.width))x\(Int(frame.height)))"
            )
        }

        // 每个动作最终会选中谁 —— 这是排查"按错按钮"最直接的一行。
        report(action: "playPause", labels: playPauseLabels, in: window)
        report(action: "next", labels: nextLabels, in: window)
        report(action: "previous", labels: previousLabels, in: window)
        report(action: "close", labels: closeLabels, exact: true, in: window)

        writeDebugLog("[ShellDump] ---- end ----")
    }

    private static func report(
        action: String,
        labels: [String],
        exact: Bool = false,
        in window: UIWindow
    ) {
        guard let control = findTransportButton(labels: labels, exactMatch: exact) else {
            writeDebugLog("[ShellDump] \(action) -> nil")
            return
        }
        let frame = control.convert(control.bounds, to: window)
        writeDebugLog(
            "[ShellDump] \(action) -> \(kind(control))"
                + " label=\"\(control.accessibilityLabel ?? "")\""
                + " frame=(\(Int(frame.minX)),\(Int(frame.minY))"
                + " \(Int(frame.width))x\(Int(frame.height)))"
        )
    }

    /// 控件的类名（诊断与去重都用它）。
    private static func kind(_ view: UIView) -> String {
        NSStringFromClass(type(of: view))
    }

    private static func collectAllControls(
        in view: UIView,
        into result: inout [UIControl]
    ) {
        if let control = view as? UIControl, isOnScreen(control) {
            result.append(control)
        }
        for subview in view.subviews {
            collectAllControls(in: subview, into: &result)
        }
    }

    // MARK: 内部

    /// 播放键的标签：**当前状态是"播放中"时它叫 Pause**，所以两组都要匹配。
    ///
    /// 这里用 `exactMatch: true`（配合下面的排除词），原因是真机实测：
    /// 模糊匹配下"暂停键"会切到**专辑页** —— 那是命中了标签里带 "play/播放" 的
    /// 别的控件（例如"播放专辑"）。精确相等 + 排除词两道闸门能挡住它。
    private static let playPauseLabels = ["pause", "play", "暂停", "播放", "继续"]
    /// 播放键要排掉的词。
    ///
    /// - 内容是"播放某个东西"的入口（专辑/歌单/电台 …），不是传输控件；
    /// - **进度条也算**：真机 dump 抓到 `playPause -> ...ProgressBar6Slider
    ///   label="曲目位置"` —— 它的标签里带"曲"、被模糊匹配命中过，
    ///   结果"暂停键"去点了进度条（表现就是按下没反应或乱跳）。
    private static let playPauseExclusions = [
        "album", "playlist", "radio", "artist", "song radio", "mix",
        "专辑", "歌单", "歌手", "电台", "播放列表",
        "曲目位置", "position", "slider", "进度",
        "随机", "shuffle", "循环", "repeat", "队列", "queue", "设备",
    ]
    private static let nextLabels = ["next", "下一首", "下一曲", "下一个"]
    private static let previousLabels = ["previous", "prev", "上一首", "上一曲", "上一个"]
    /// 关闭/收起。**必须精确匹配**：`contains` 会把 "Close Friends"（Spotify 的
    /// 好友动态入口）也算进来。
    private static let closeLabels = ["close", "dismiss", "collapse", "关闭", "收起"]

    /// 按标签在窗口里找可点的控件。
    ///
    /// 只找 `UIControl`（能发事件），并且要求它在屏幕上（`window != nil`、尺寸非零），
    /// 避免命中离屏的备份视图或无障碍占位元素。
    ///
    /// - Parameters:
    ///   - exactMatch: true 时要求标签**整体相等**（忽略大小写与空白），
    ///     用于 "close" 这种容易误伤的短词。
    ///   - excluding: 命中这些词的控件直接跳过。用于"找播放键但排掉播放专辑/
    ///     播放列表"这类场景 —— 这正是真机上"暂停键切去专辑"的成因。
    private static func findTransportButton(
        labels: [String],
        excluding: [String] = [],
        exactMatch: Bool = false
    ) -> UIControl? {
        guard let window = keyWindow else { return nil }

        var matches: [UIControl] = []
        collectControls(
            in: window,
            labels: labels,
            excluding: excluding,
            exactMatch: exactMatch,
            into: &matches
        )

        guard !matches.isEmpty else { return nil }
        // 取面积最大的那个：真正的大按钮 > 列表里的同义小图标。
        return matches.max { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
    }

    private static func collectControls(
        in view: UIView,
        labels: [String],
        excluding: [String],
        exactMatch: Bool,
        into result: inout [UIControl]
    ) {
        if let control = view as? UIControl,
           isOnScreen(control),
           matchesLabel(control, labels: labels, exactMatch: exactMatch),
           !matchesLabel(control, labels: excluding, exactMatch: false) {
            result.append(control)
        }
        for subview in view.subviews {
            collectControls(
                in: subview,
                labels: labels,
                excluding: excluding,
                exactMatch: exactMatch,
                into: &result
            )
        }
    }

    private static func isOnScreen(_ view: UIView) -> Bool {
        guard view.window != nil, !view.isHidden, view.alpha > 0.01 else { return false }
        return view.bounds.width > 1 && view.bounds.height > 1
    }

    private static func matchesLabel(
        _ view: UIView,
        labels: [String],
        exactMatch: Bool
    ) -> Bool {
        let candidates = [
            view.accessibilityLabel,
            view.accessibilityIdentifier,
            (view as? UIButton)?.title(for: .normal),
        ]
        for case let text? in candidates {
            let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if exactMatch {
                if labels.contains(where: { lowered == $0 }) { return true }
            } else if labels.contains(where: { lowered.contains($0) }) {
                return true
            }
        }
        return false
    }

    private static func sendTap(to control: UIControl) {
        control.sendActions(for: .touchUpInside)
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

// MARK: - 播放状态投影

/// 把每帧的播放位置投影成"壳"需要的三个量：当前时间、总时长、是否在播放。
///
/// - 总时长：取 `SPTPlayerTrack.trackDurationMilliseconds`（已有字段），失败则用
///   歌词最后一行的时间兜底（AMLL 的 TTML 自带 `dur`，日志里可见）。
/// - 是否在播放：**靠位置是否在变来推断**。不去猜 `isPlaying` 这种未公开属性 ——
///   位置连续两帧变化即"播放中"，长时间不动即"暂停"。这个方法在暂停、切歌、
///   seek 之后都能自洽，且不依赖任何私有签名。
@available(iOS 26.0, *)
@MainActor
final class AppleMusicLyricsPlaybackProjection: ObservableObject {

    /// 当前播放位置（秒）。
    @Published private(set) var time: TimeInterval = 0
    /// 总时长（秒）。取不到时为 0，壳会隐藏进度条。
    @Published private(set) var duration: TimeInterval = 0
    /// 是否正在播放。
    @Published private(set) var isPlaying: Bool = false

    private let positionProvider: () -> TimeInterval?
    private var lastTime: TimeInterval?
    private var lastDurationRefresh: Date = .distantPast

    init(positionProvider: @escaping () -> TimeInterval?) {
        self.positionProvider = positionProvider
    }

    /// 每帧调用。内部做阈值判断，值没实质变化就不发通知（避免每帧整壳重绘）。
    func refresh() {
        let newTime = positionProvider() ?? time
        if abs(newTime - time) > 0.01 {
            // 位置在推进 → 正在播放。注意：拖动进度条时位置也会跳，所以
            // "正在播放"只用来选图标，不参与拖动逻辑。
            isPlaying = newTime > time
            time = newTime
        } else {
            // 位置长时间不动 → 暂停（判据宽松一点：连续不动就是没在放）。
            isPlaying = false
        }

        // 时长不必每帧读（它一次播放内不变），1 秒刷一次足够。
        let now = Date()
        if now.timeIntervalSince(lastDurationRefresh) > 1 {
            lastDurationRefresh = now
            if let ms = statefulPlayer?.currentTrack()?.trackDurationMilliseconds, ms > 0 {
                duration = TimeInterval(ms) / 1000
            }
        }
    }
}

// MARK: - 自绘壳

/// 全屏歌词页的"壳"**底部**：进度条 + 时间 + 播放控制。
///
/// 标题栏在 `AppleMusicLyricsOverlayView.shellHeader`（它不需要播放状态，
/// 所以留在那边，这里只管底部这块）。
@available(iOS 26.0, *)
struct AppleMusicLyricsControls: View {

    @ObservedObject var projection: AppleMusicLyricsPlaybackProjection

    /// 主色（与歌词、页脚同一色系）。
    var primaryColor: Color = .white
    /// 拖动进度条 → 跳到该位置（秒）。
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        VStack(spacing: 0) {
            AppleMusicLyricsProgressBar(
                time: projection.time,
                duration: projection.duration,
                primaryColor: primaryColor,
                onSeek: onSeek
            )
            .padding(.horizontal, 20)

            HStack {
                Text(Self.clock(projection.time))
                Spacer()
                Text(
                    projection.duration > 0
                        ? "-" + Self.clock(max(projection.duration - projection.time, 0))
                        : ""
                )
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(primaryColor.opacity(0.62))
            .padding(.horizontal, 20)
            .padding(.top, 3)

            Spacer().frame(height: 12)

            transportRow

            Spacer().frame(height: 4)
        }
        .padding(.horizontal, 12)
    }

    // MARK: 三键

    private var transportRow: some View {
        HStack(spacing: 44) {
            glyphButton("backward.fill", size: 22) {
                WordByWordPlaybackControl.skipToPrevious()
            }
            glyphButton(projection.isPlaying ? "pause.fill" : "play.fill", size: 30) {
                WordByWordPlaybackControl.togglePlayPause()
            }
            glyphButton("forward.fill", size: 22) {
                WordByWordPlaybackControl.skipToNext()
            }
        }
    }

    private func glyphButton(
        _ systemName: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(primaryColor)
                .frame(width: size + 26, height: size + 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `m:ss`。与 Spotify 原生一致（不补零到 `mm:ss`）。
    private static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// 进度条：4pt 细轨 + 白色已播段 + 可拖动的圆点。
///
/// 为什么不用 SwiftUI 的 `Slider`：它自带系统外形（灰轨 + 大圆点 + 内边距），
/// 和 Spotify 原生那条细线差得远 —— 既然目标是"看不出换过壳"，就自己画。
@available(iOS 26.0, *)
private struct AppleMusicLyricsProgressBar: View {

    let time: TimeInterval
    let duration: TimeInterval
    let primaryColor: Color
    let onSeek: (TimeInterval) -> Void

    @GestureState private var isScrubbing = false
    @State private var scrubbedFraction: Double?

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 11

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = displayedFraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(primaryColor.opacity(0.28))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(primaryColor.opacity(0.95))
                    .frame(width: width * fraction, height: trackHeight)

                Circle()
                    .fill(primaryColor)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: width * fraction - thumbSize / 2)
                    .opacity(isScrubbing ? 1 : 0.9)
            }
            .frame(height: max(trackHeight, thumbSize))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isScrubbing) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        scrubbedFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { _ in
                        if let fraction = scrubbedFraction, duration > 0 {
                            onSeek(fraction * duration)
                        }
                        scrubbedFraction = nil
                    }
            )
        }
        .frame(height: max(trackHeight, thumbSize))
    }

    private var displayedFraction: Double {
        if let scrubbedFraction { return scrubbedFraction }
        guard duration > 0 else { return 0 }
        return min(max(time / duration, 0), 1)
    }
}
