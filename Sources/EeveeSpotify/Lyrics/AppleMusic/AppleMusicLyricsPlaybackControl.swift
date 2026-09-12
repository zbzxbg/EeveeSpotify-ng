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

        if let button = findTransportButton(labels: playPauseLabels) {
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

        if let button = findTransportButton(labels: nextLabels) {
            writeDebugLog("[Shell] skipToNext via native button")
            sendTap(to: button)
            return true
        }

        writeDebugLog("[Shell] ⚠️ skipToNext unavailable")
        return false
    }

    @discardableResult
    static func skipToPrevious() -> Bool {
        if let player = statefulPlayer as? NSObject {
            for name in ["skipToPrevious", "previous", "skipToPreviousTrack"] {
                let selector = Selector(name)
                guard player.responds(to: selector) else { continue }
                writeDebugLog("[Shell] skipToPrevious via statefulPlayer.\(name)()")
                player.perform(selector)
                return true
            }
        }

        if let button = findTransportButton(labels: previousLabels) {
            writeDebugLog("[Shell] skipToPrevious via native button")
            sendTap(to: button)
            return true
        }

        writeDebugLog("[Shell] ⚠️ skipToPrevious unavailable")
        return false
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

    // MARK: 内部

    /// 播放键的标签：**当前状态是"播放中"时它叫 Pause**，所以两组都要匹配。
    private static let playPauseLabels = ["pause", "play", "暂停", "播放", "继续"]
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
    /// - Parameter exactMatch: true 时要求标签**整体相等**（忽略大小写与空白），
    ///   用于 "close" 这种容易误伤的短词。
    private static func findTransportButton(
        labels: [String],
        exactMatch: Bool = false
    ) -> UIControl? {
        guard let window = keyWindow else { return nil }

        var matches: [UIControl] = []
        collectControls(in: window, labels: labels, exactMatch: exactMatch, into: &matches)

        guard !matches.isEmpty else { return nil }
        // 取面积最大的那个：真正的大按钮 > 列表里的同义小图标。
        return matches.max { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
    }

    private static func collectControls(
        in view: UIView,
        labels: [String],
        exactMatch: Bool,
        into result: inout [UIControl]
    ) {
        if let control = view as? UIControl,
           isOnScreen(control),
           matchesLabel(control, labels: labels, exactMatch: exactMatch) {
            result.append(control)
        }
        for subview in view.subviews {
            collectControls(in: subview, labels: labels, exactMatch: exactMatch, into: &result)
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
