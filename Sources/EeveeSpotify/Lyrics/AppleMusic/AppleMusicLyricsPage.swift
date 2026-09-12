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

    init(
        lines: [LyricLine],
        playbackTime: TimeInterval,
        background: AnyView,
        onClose: (() -> Void)? = nil,
        onSeek: ((TimeInterval) -> Void)? = nil,
        contentInsets: EdgeInsets = EdgeInsets(top: 60, leading: 24, bottom: 120, trailing: 24)
    ) {
        self.lines = lines
        self.playbackTime = playbackTime
        self.background = background
        self.onClose = onClose
        self.onSeek = onSeek
        self.contentInsets = contentInsets
    }

    private static var profile: AppleMusicLyricsMotionProfile { .iOS26_6 }

    /// 当前播放位置（由纯逻辑时间轴给出，不在这里自己算）。
    private var position: LyricPlaybackPosition {
        LyricPlaybackTimeline.position(at: playbackTime, in: lines)
    }

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(
                        alignment: .leading,
                        spacing: CGFloat(Self.profile.paragraphSpacing)
                    ) {
                        ForEach(lines) { line in
                            row(for: line, position: position)
                                .id(line.id)
                        }
                    }
                    .padding(.top, contentInsets.top)
                    .padding(.bottom, contentInsets.bottom)
                    .padding(.horizontal, contentInsets.leading)
                }
                .onChange(of: position.highlightedLyricID) { _, newValue in
                    guard let newValue else { return }
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
            }

            if let onClose {
                closeButton(onClose)
            }
        }
    }

    // MARK: 单行

    @ViewBuilder
    private func row(
        for line: LyricLine,
        position: LyricPlaybackPosition
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
            constrainedWidth: nil,
            alignment: .leading,
            appliesTimingEffects: isActive
        )
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
            onSeek?(line.time)
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
