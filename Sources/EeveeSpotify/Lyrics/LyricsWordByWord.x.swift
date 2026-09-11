import Orion
import UIKit
import ObjectiveC
import SwiftUI

// MARK: - 逐字歌词渲染模块（MVP）
//
// 结构：
//   WordByWordPositionResolver — 安全多策略定位播放进度（运行时探测，responds/ivar 检查后再读，绝不裸调）
//   WordByWordPlaybackClock   — CADisplayLink 时钟，把进度喂给叠加视图
//   LyricsWordByWordOverlayView — UIKit 叠加视图：逐行 UILabel + 当前词 NSAttributedString 高亮 + 自动滚动
//   WordByWordHost            — 挂载/卸载 overlay（挂在 Spotify 全屏歌词 VC 上）
//
// 前提（来自 Spotify 二进制逆向）：
//   进度候选：playbackPosition(Double)、currentPlaybackTime(Double)、currentTrackTimeSecs(Int64 秒)
//   挂载点：Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController（新版）/ Lyrics_CoreImpl.LyricsOnlyViewController（iOS14）
//   开关：复用 ngzhwm_wordByWordLyrics

var currentLyricsDto: LyricsDto?
var currentLyricsVersion: Int = 0
/// 最终生效的歌词背景色（ARGB），CustomLyrics 算完 colors 后写入，供 overlay 与原生模块同色。
var currentLyricsBackgroundColorARGB: UInt32 = 0
/// 歌词提供者文本（如 "PetitLyrics (EeveeSpotify)"），用于 overlay 底部展示。
var currentLyricsProvider: String = ""

// MARK: - 位置解析

@objc protocol WordByWordPositionDoubleGetter { func playbackPosition() -> Double }
@objc protocol WordByWordCurrentPlaybackTimeDoubleGetter { func currentPlaybackTime() -> Double }
@objc protocol WordByWordCurrentTrackTimeSecsGetter { func currentTrackTimeSecs() -> Int64 }
@objc protocol WordByWordPlayerPositionGetter { func position() -> Double }
@objc protocol WordByWordSeekProtocol { func seekTo(_ seconds: Double) }

final class WordByWordPositionResolver {
    static let shared = WordByWordPositionResolver()

    private var getter: (() -> Double)?
    private(set) var sourceLabel: String = "unresolved"
    private var sampleCount = 0
    private var didLogUnresolved = false

    /// 逐策略探测：先试方法（responds 检查后 Dynamic.convert 调用），再试 ivar（class_getInstanceVariable 检查后读取）。
    /// 任一环节检查不通过就跳过，保证永不因猜错签名崩溃。
    func resolve() {
        // 首选：statefulPlayer.position() —— 已由 runtime dump 确认（d16@0:8 = double 无参，秒）
        if let p = statefulPlayer as? NSObject, p.responds(to: Selector("position")) {
            let g = Dynamic.convert(p, to: WordByWordPlayerPositionGetter.self)
            getter = { g.position() }
            sourceLabel = "statefulPlayer.position() -> Double"
            writeDebugLog("[WordByWord] position source: \(sourceLabel)")
            return
        }

        var candidates: [(String, NSObject)] = []
        if let p = statefulPlayer as? NSObject { candidates.append(("statefulPlayer", p)) }
        if let vc = nowPlayingScrollViewController as? NSObject {
            candidates.append(("scrollVC", vc))
            let vm = Ivars<NSObject>(vc).scrollViewModel
            candidates.append(("scrollViewModel", vm))
        }
        if let npv = npvScrollViewController as? NSObject { candidates.append(("npvVC", npv)) }

        for (label, obj) in candidates {
            if obj.responds(to: Selector("playbackPosition")) {
                let g = Dynamic.convert(obj, to: WordByWordPositionDoubleGetter.self)
                getter = { g.playbackPosition() }
                sourceLabel = "\(label).playbackPosition() -> Double"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
        }
        for (label, obj) in candidates {
            if obj.responds(to: Selector("currentPlaybackTime")) {
                let g = Dynamic.convert(obj, to: WordByWordCurrentPlaybackTimeDoubleGetter.self)
                getter = { g.currentPlaybackTime() }
                sourceLabel = "\(label).currentPlaybackTime() -> Double"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
        }
        for (label, obj) in candidates {
            if let value = ivarInt64(obj, "currentTrackTimeSecs") {
                getter = { Double(value) }
                sourceLabel = "\(label).currentTrackTimeSecs -> Int64(秒)"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
            if let value = ivarDouble(obj, "playbackPosition") {
                getter = { value }
                sourceLabel = "\(label).playbackPosition ivar -> Double"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
        }
        if !didLogUnresolved {
            didLogUnresolved = true
            writeDebugLog("[WordByWord] no position source resolved — will retry on next tick")
        }
    }

    /// 返回秒（双精度）。源不可用返回 nil。
    /// 启动时候选对象（statefulPlayer/scrollViewModel 等）可能还没就绪，
    /// 未解析成功时每次调用都重试一次，直到命中某个策略。
    func currentPositionSeconds() -> Double? {
        if getter == nil { resolve() }
        guard let getter else { return nil }
        let raw = getter()
        if sampleCount < 5 {
            sampleCount += 1
            writeDebugLog("[WordByWord] pos sample \(sampleCount): \(raw)")
        }
        return raw
    }

    private func ivarInt64(_ obj: NSObject, _ name: String) -> Int64? {
        for ivarName in [name, "_\(name)"] {
            guard let ivar = class_getInstanceVariable(type(of: obj), ivarName) else { continue }
            guard let rawPointer = object_getIvar(obj, ivar) as AnyObject? else { return nil }
            return unsafeBitCast(rawPointer, to: Int64.self)
        }
        return nil
    }

    private func ivarDouble(_ obj: NSObject, _ name: String) -> Double? {
        for ivarName in [name, "_\(name)"] {
            guard let ivar = class_getInstanceVariable(type(of: obj), ivarName) else { continue }
            guard let rawPointer = object_getIvar(obj, ivar) as AnyObject? else { return nil }
            return unsafeBitCast(rawPointer, to: Double.self)
        }
        return nil
    }
}

// MARK: - 点行跳转

final class WordByWordSeeker {
    static func seek(toMs ms: Int) {
        guard let player = statefulPlayer as? NSObject, player.responds(to: Selector("seekTo:")) else {
            writeDebugLog("[WordByWord] seekTo: unavailable on statefulPlayer")
            return
        }
        let g = Dynamic.convert(player, to: WordByWordSeekProtocol.self)
        g.seekTo(Double(ms) / 1000)
        writeDebugLog("[WordByWord] seek to \(ms)ms")
    }
}

// MARK: - 播放时钟

final class WordByWordPlaybackClock {
    static let shared = WordByWordPlaybackClock()

    private var displayLink: CADisplayLink?
    private(set) var currentMs: Double = 0
    var onChange: ((Double) -> Void)?

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
        let ms: Double
        if let seconds = WordByWordPositionResolver.shared.currentPositionSeconds() {
            ms = seconds * 1000
        } else {
            ms = currentMs
        }
        currentMs = ms
        onChange?(ms)
    }
}

// MARK: - 叠加视图

/// 歌词行：逐词填充标签 + 所属行下标（`lineIndex` 定义在 `KaraokeLineLabel` 上，
/// 仅用于日志定位）。
/// 填充机制见 `KaraokeLineLabel`（双层文字 + 逐行渐变遮罩 + CAKeyframeAnimation）。
private final class LineLabel: KaraokeLineLabel {}

final class LyricsWordByWordOverlayView: UIView, UIScrollViewDelegate {

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var lineLabels: [LineLabel] = []
    private var displayTexts: [String] = []
    private var wordNSRanges: [[NSRange]] = []
    private var wordIndices: [[Int]] = []
    private var providerLabel: UILabel?
    /// 是否在底部显示「歌词提供者」（全屏显示，内嵌不显示）。
    var showsProviderFooter = false
    /// 是否显示行级译文（全屏显示；内嵌「预览歌词」不显示）。
    var showsTranslation = true
    /// 行级译文标签（每行原文下面一行小字），用于 rebuild 清理。
    private var translationLabels: [UILabel] = []

    private var dto: LyricsDto?
    private var dtoVersion = -1
    private var activeLineIndex = -1
    private var activeWordIndex = -1
    /// 上一次喂进来的播放进度（毫秒）。用于识别「暂停 / 进度未变」，
    /// 跳过整段行-词扫描 —— 但填充的漂移看门狗仍要走（见 setCurrentTime）。
    private var lastSeenMs: Double = .nan
    /// 最近一次扫描到的行/词下标，供进度未变时复用。
    private var bestIndexCache: (line: Int, word: Int) = (-1, -1)
    /// 歌词数据或行标签被重建后置位，强制下一帧重新扫描。
    private var lineIndicesMayHaveChanged = true

    private let lineColor = UIColor.black
    private let activeLineColorValue = UIColor.white
    /// 行级译文字号（比歌词小）。
    private let translationFontSize: CGFloat = 16
    /// 行级译文颜色：与未唱歌词（其余行）一致的黑色。
    private let translationColor = UIColor.black
    /// 当前行内「未唱」部分的透明度。对齐参考实现
    /// （`KaraokeLineView.swift` 用 `white.opacity(0.35)`）：已唱纯白、
    /// 未唱 35%，对比度 2.86:1。原来取 0.45 偏亮，层次不够。
    private let unsungWordOpacity: CGFloat = 0.35
    /// 背景色缓存：每次 rebuild（换歌/换数据）后按「定制」选项重新计算一次。
    private var resolvedBackgroundColor: UIColor?
    /// 顶部渐隐层（scrim）：背景色 → 透明，让上滚的歌词在顶部渐隐退出。
    private let topFadeView = UIView()
    private let topFadeLayer = CAGradientLayer()
    /// 底部渐隐层（scrim）：透明 → 背景色，让从底部进入的歌词渐隐进入。
    private let bottomFadeView = UIView()
    private let bottomFadeLayer = CAGradientLayer()
    private let topFadeHeight: CGFloat = 48

    /// 手动滚动时暂停自动跟随，直到该时间点
    private var autoScrollPauseUntil: Date = .distantPast
    /// 诊断：节流打印当前高亮状态
    private var lastDiagnosticLog: Date = .distantPast
    /// 当前行在视口中的目标位置（距顶部比例）。
    ///
    /// 取值依据：SPlayer 默认 `lyricsScrollOffset = 0.25`（锚点为 top）、
    /// Apple 自己 dex 里读出的 `APPLE_LYRICS_INITIAL_ANCHOR_Y_FRACTION ≈ 0.22`、
    /// AMLL 核心 0.35（锚点为 center，换算到 top 约 0.4）。
    /// 原来取 0.40，比 SPlayer 和 Apple 都偏下近 20 个百分点。
    private let activeLineViewportFraction: CGFloat = 0.25
    /// 自动滚动动画时长（秒），越小越「干脆」。
    private let scrollAnimationDuration: TimeInterval = 0.20
    /// 歌词行字号（对照 Spotify 原生歌词放大）。
    private let lyricsFontSize: CGFloat = 22
    /// 歌词行字体。填充用的轴向测量必须和 label 用同一字体，
    /// 因此统一从这里取，避免两处各写一份 systemFont 参数。
    private var lyricsFont: UIFont {
        .systemFont(ofSize: lyricsFontSize, weight: .semibold)
    }
    /// 歌词行左右内边距（对照「歌词」标题的左缩进）；全屏歌词可单独调大。
    private var lyricsSideInset: CGFloat = 16
    /// 歌词块顶部留白（未滚动时第一行的起始高度）。
    private let lyricsTopPadding: CGFloat = 18
    // 左右/宽度约束的可更新引用（供 setSideInset 调整）
    private var stackLeadingConstraint: NSLayoutConstraint?
    private var stackTrailingConstraint: NSLayoutConstraint?
    private var stackWidthConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 顶部渐隐贴安全区顶部，底部渐隐贴安全区底部。
        topFadeView.frame = CGRect(x: 0, y: safeAreaInsets.top, width: bounds.width, height: topFadeHeight)
        topFadeLayer.frame = topFadeView.bounds
        bottomFadeView.frame = CGRect(
            x: 0,
            y: bounds.height - safeAreaInsets.bottom - topFadeHeight,
            width: bounds.width,
            height: topFadeHeight
        )
        bottomFadeLayer.frame = bottomFadeView.bounds
    }

    /// 调整歌词行左右边距（全屏用到更大的左边距时调用）。
    func setSideInset(_ inset: CGFloat) {
        lyricsSideInset = inset
        stackLeadingConstraint?.constant = inset
        stackTrailingConstraint?.constant = -inset
        stackWidthConstraint?.constant = -(2 * inset)
    }

    private func setupView() {
        backgroundColor = .clear

        topFadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        topFadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
        topFadeView.layer.addSublayer(topFadeLayer)
        topFadeView.isUserInteractionEnabled = false
        topFadeView.isHidden = true

        bottomFadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        bottomFadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
        bottomFadeView.layer.addSublayer(bottomFadeLayer)
        bottomFadeView.isUserInteractionEnabled = false
        bottomFadeView.isHidden = true

        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.spacing = 18
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        scrollView.addSubview(stackView)
        addSubview(topFadeView)
        addSubview(bottomFadeView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: lyricsTopPadding),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -60),
        ])

        // 左右/宽度单独建，便于全屏时调整左边距
        let leading = stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: lyricsSideInset)
        let trailing = stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -lyricsSideInset)
        let width = stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -(2 * lyricsSideInset))
        NSLayoutConstraint.activate([leading, trailing, width])
        stackLeadingConstraint = leading
        stackTrailingConstraint = trailing
        stackWidthConstraint = width
    }

    /// 每帧由时钟调用：惰性取 dto、词级高亮、自动滚动。
    func setCurrentTime(_ ms: Double) {
        if dtoVersion != currentLyricsVersion {
            dto = currentLyricsDto
            dtoVersion = currentLyricsVersion
            rebuild()
        }

        // 只有「有足够多行真逐字 且 时间同步」才显示逐字；
        // 否则（无逐字 / 坏逐字 / 静态歌词 / 还没加载到 dto）一律透明 + 隐藏标签，回退 Spotify 原生。
        guard let dto, dto.timeSynced, hasUsableWordLevel(dto) else {
            backgroundColor = .clear
            stackView.isHidden = true
            topFadeView.isHidden = true
            bottomFadeView.isHidden = true
            isUserInteractionEnabled = false   // 回退原生时让触摸穿透，别挡住原生歌词滚动
            return
        }

        let targetBackground = resolvedBackgroundColor ?? overlayBackgroundColor()
        resolvedBackgroundColor = targetBackground
        if backgroundColor != targetBackground {
            backgroundColor = targetBackground
            topFadeLayer.colors = [
                targetBackground.cgColor,
                targetBackground.withAlphaComponent(0).cgColor
            ]
            bottomFadeLayer.colors = [
                targetBackground.withAlphaComponent(0).cgColor,
                targetBackground.cgColor
            ]
            stackView.isHidden = false
            isUserInteractionEnabled = true
            updateFadeVisibility()
        }

        // 播放暂停时进度不再变化：整段重算（含行/词扫描与滚动态）都没有意义，
        // 但漂移看门狗仍需要跑 —— 否则 seek 后恢复会停在旧位置。
        if ms == lastSeenMs, !lineIndicesMayHaveChanged, bestIndexCache.line >= 0 {
            writeThrottledDiagnostic(ms: ms, line: bestIndexCache.line, word: bestIndexCache.word, dto: dto)
            pushFill(lineIndex: bestIndexCache.line, ms: ms, dto: dto)
            return
        }
        lastSeenMs = ms
        lineIndicesMayHaveChanged = false

        // 当前行 = 最后一个 offsetMs <= 当前进度 的行，因此从后往前找，
        // 命中即可跳出（长歌词也是 O(行数) 的最坏情况，但平均远小于此）。
        var bestLine = -1
        var bestWord = -1
        for index in stride(from: dto.lines.count - 1, through: 0, by: -1) {
            guard let offset = dto.lines[index].offsetMs, Double(offset) <= ms else { continue }
            bestLine = index
            if let words = dto.lines[index].words {
                for j in words.indices where Double(words[j].startMs) <= ms {
                    bestWord = j
                }
            }
            break
        }
        bestIndexCache = (line: bestLine, word: bestWord)

        writeThrottledDiagnostic(ms: ms, line: bestLine, word: bestWord, dto: dto)

        let lineChanged = bestLine != activeLineIndex

        if lineChanged {
            let oldIndex = activeLineIndex
            activeLineIndex = bestLine

            if bestLine == oldIndex + 1 {
                // 正常前进：旧行补完并淡出到暗，新行从暗淡入。
                if oldIndex >= 0, oldIndex < lineLabels.count {
                    let previous = lineLabels[oldIndex]
                    previous.setFullyLit(true)
                    previous.fade(toLit: false)
                }
                if bestLine >= 0, bestLine < lineLabels.count {
                    let current = lineLabels[bestLine]
                    current.setFullyLit(false)
                    current.fade(toLit: true)
                }
            } else {
                // 跳转/回退：整列表重涂 —— 已唱过行亮、当前行暗等填充、未到行暗。
                repaintAllLines(upTo: bestLine)
            }

            // 只在行切换时滚动；词切换不重复滚动，避免动画被反复打断产生卡顿
            if bestLine >= 0 {
                scrollToLine(bestLine)
            } else {
                // 回到歌曲开头（当前时间早于第一行）时滚回顶部
                scrollToTop()
            }
        }

        activeWordIndex = bestWord

        // 已唱过的行保持满亮（新行从暗淡入期间重叠一行，保证不闪）。
        if lineChanged {
            for index in 0..<max(0, bestLine) where index < lineLabels.count {
                lineLabels[index].setFullyLit(true)
            }
            // 行级层次：AMLL 在逐词模式下**不靠透明度区分非活动行**，
            // 区分全靠缩放（0.97）与模糊。这里按「距当前行几行」设置。
            applyLineEmphasis(activeLine: bestLine)
        }

        pushFill(lineIndex: bestLine, ms: ms, dto: dto)
    }

    /// 按「距当前行几行」给每行设置缩放与透明度层次。
    ///
    /// AMLL 的做法：非活动行 `scale = 0.97`，透明度在逐词模式下**不变**，
    /// 层次感主要来自缩放与模糊梯度。这里只做缩放 + 轻度透明度衰减
    /// （模糊逐行动画在 iOS 上代价太高，暂不接）。
    private func applyLineEmphasis(activeLine: Int) {
        guard !lineLabels.isEmpty else { return }
        let focus = max(0, activeLine)
        for (index, label) in lineLabels.enumerated() {
            label.setLineEmphasis(distance: abs(index - focus))
        }
    }

    /// 把播放进度喂给当前行的填充。
    ///
    /// 词级数据是否可用由 `KaraokeLineLabel` 内部统一判定
    /// （见 `WordTimingResolver.isUsableForFill`）：不可用时它自动退化成
    /// 行级填充基例，这里不再重复判定一次，避免阈值散落在两处。
    private func pushFill(lineIndex: Int, ms: Double, dto: LyricsDto) {
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        guard let offset = dto.lines[lineIndex].offsetMs else { return }

        // 时间窗：本行 offsetMs → 下一行 offsetMs（末行用 +8s 兜底，
        // 保证最后一个词始终有一个上界可用）。
        let segmentEnd = (lineIndex + 1 < dto.lines.count
            ? dto.lines[lineIndex + 1].offsetMs
            : nil) ?? (offset + 8000)

        lineLabels[lineIndex].setFill(
            words: dto.lines[lineIndex].words ?? [],
            segmentStartMs: offset,
            segmentEndMs: segmentEnd,
            currentTime: ms / 1000
        )
    }

    /// 诊断：节流打印当前高亮状态（每 1s 一次），用于对比数据时间轴与实际渲染。
    private func writeThrottledDiagnostic(
        ms: Double,
        line: Int,
        word: Int,
        dto: LyricsDto
    ) {
        guard Date().timeIntervalSince(lastDiagnosticLog) > 1.0 else { return }
        lastDiagnosticLog = Date()

        var wordInfo = "no-line"
        if line >= 0, line < dto.lines.count {
            if let words = dto.lines[line].words, !words.isEmpty {
                if word >= 0, word < words.count {
                    wordInfo = "w\(word)=\"\(words[word].text)\"@\(words[word].startMs)ms"
                } else {
                    wordInfo = "w=none-yet"
                }
            } else {
                wordInfo = "words=nil"
            }
        }

        // 填充链路自检：轴算错、或「某些词不亮」这类问题，都靠这里定位。
        // `rowW` 与 `fullW` 必须相等 —— 硬边遮罩铺满时宽度就是行宽，
        // 不等就说明几何算错了。
        var fillInfo = "no-fill"
        if line >= 0, line < lineLabels.count {
            let label = lineLabels[line]
            fillInfo = "\(label.axisDiagnostics) fill=\(label.lastVariantSummary) | \(label.fillDiagnostics)"
        }

        // 逐词动效自检：span 为空就是「某个词不动」的原因；
        // progress 应该随着词内推进从 0 走到 1。
        var motionInfo = "no-motion"
        if line >= 0, line < lineLabels.count {
            motionInfo = lineLabels[line].bounceDiagnostics
        }

        writeDebugLog("[WordByWord] t=\(Int(ms))ms line=\(line) \(wordInfo) | \(fillInfo) | \(motionInfo)")
    }

    /// 逐字数据是否可用：至少一半行有「多词」级时间轴（words.count >= 2）。
    /// 整行一个词 / 全退化 / 词级时间轴错位 等坏数据会低于阈值，回退原生行级。
    private func hasUsableWordLevel(_ dto: LyricsDto) -> Bool {
        let lines = dto.lines
        guard !lines.isEmpty else { return false }
        let wordLevelLines = lines.filter { ($0.words?.count ?? 0) >= 2 }.count
        return wordLevelLines * 10 >= lines.count * 5  // >= 50%
    }

    private func rebuild() {
        for label in lineLabels { label.removeFromSuperview() }
        lineLabels = []
        for label in translationLabels { label.removeFromSuperview() }
        translationLabels = []
        providerLabel?.removeFromSuperview()
        providerLabel = nil
        displayTexts = []
        wordNSRanges = []
        wordIndices = []
        activeLineIndex = -1
        activeWordIndex = -1
        resolvedBackgroundColor = nil
        lastSeenMs = .nan
        bestIndexCache = (-1, -1)
        lineIndicesMayHaveChanged = true

        guard let dto else { return }

        for (index, line) in dto.lines.enumerated() {
            let built = buildDisplayText(for: line)
            let label = LineLabel()
            label.lineIndex = index
            label.setColors(lit: activeLineColorValue, dim: activeLineColorValue)
            label.setDimOpacity(unsungWordOpacity)
            label.setFont(lyricsFont)
            label.setLyric(built.text, wordRanges: built.nsRanges)
            // 初始全部为暗：由 setCurrentTime 按播放进度点亮。
            label.setFullyLit(false)
            label.isUserInteractionEnabled = true
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleLineTap(_:))))

            // 每行用竖排 stack 包住：原文行 + 可选译文行
            let lineStack = UIStackView()
            lineStack.axis = .vertical
            lineStack.spacing = 4
            lineStack.addArrangedSubview(label)

            if showsTranslation, let translation = dto.translation, index < translation.lines.count {
                let t = translation.lines[index]
                if !t.isEmpty {
                    let translationLabel = UILabel()
                    translationLabel.numberOfLines = 0
                    translationLabel.textAlignment = .left
                    translationLabel.font = .systemFont(ofSize: translationFontSize, weight: .regular)
                    translationLabel.textColor = translationColor
                    translationLabel.text = t
                    translationLabel.isUserInteractionEnabled = false
                    lineStack.addArrangedSubview(translationLabel)
                    translationLabels.append(translationLabel)
                }
            }

            stackView.addArrangedSubview(lineStack)
            lineLabels.append(label)
            displayTexts.append(built.text)
            wordNSRanges.append(built.nsRanges)
            wordIndices.append(built.indices)
        }

        // 底部：歌词提供者（仅全屏显示；原生歌词表格 footer 里的信息，overlay 覆盖后补出来）
        if showsProviderFooter, !currentLyricsProvider.isEmpty {
            let footer = UILabel()
            footer.numberOfLines = 0
            footer.textAlignment = .left
            footer.font = .systemFont(ofSize: 14, weight: .regular)
            footer.textColor = lineColor
            footer.text = "word_by_word_lyrics_provider".localizeWithFormat(currentLyricsProvider)
            stackView.addArrangedSubview(footer)
            providerLabel = footer
        }

        // 先把布局跑完：轴向测量依赖 label 的**已布局宽度**，
        // 否则首帧起 `KaraokeLineLabel` 拿不到可用几何，填充会晚一帧才出现。
        layoutIfNeeded()
    }

    /// 由词文本拼出行显示文本，并记录每个词在文本中的 NSRange。
    ///
    /// 空格 token 保留、空文本词跳过 —— 与旧的 `buildDisplayText` 完全一致，
    /// 保证 label.text 与喂给轴向测量的字符串逐字符相同。
    /// NSRange 直接交给 `KaraokeLineLabel` 换算成展平轴边界，
    /// 因此这里不再需要 `Range<String.Index>`。
    private func buildDisplayText(
        for line: LyricsLineDto
    ) -> (text: String, nsRanges: [NSRange], indices: [Int]) {
        guard let words = line.words, !words.isEmpty else {
            return (line.content, [], [])
        }

        var text = ""
        var ranges: [NSRange] = []
        var indices: [Int] = []
        for (index, word) in words.enumerated() {
            guard !word.text.isEmpty else { continue }
            let start = (text as NSString).length
            text += word.text
            let end = (text as NSString).length
            guard end > start else { continue }
            ranges.append(NSRange(location: start, length: end - start))
            indices.append(index)
        }
        guard !text.isEmpty else { return (line.content, [], []) }
        return (text, ranges, indices)
    }

    /// 行级重涂（跳转/回退时用）：已唱过的行满亮，其余全暗。
    /// 当前行由随后的 `setFill` 接管 —— 它会从暗重新扫到当前进度。
    private func repaintAllLines(upTo activeIndex: Int) {
        for (index, label) in lineLabels.enumerated() {
            let isPast = index < activeIndex
            label.setFullyLit(isPast)
            label.fade(toLit: isPast)
        }
    }

    // MARK: 背景取色（跟随「定制」选项）

    /// 与 CustomLyrics 里原生日志歌词的取色逻辑一致：
    /// 显示原始颜色 → 正在播放背景色；静态色 → 用户所选；
    /// 否则专辑提取色/播放背景色按归一化因子调整；都没有 → 灰。
    private func overlayBackgroundColor() -> UIColor {
        // 优先用 CustomLyrics 最终写回的原生歌词背景色（与模块头同色，保证两者一致）；
        // 尚未就绪（== 0）时回退到旧的取色链路。
        if currentLyricsBackgroundColorARGB != 0 {
            let argb = currentLyricsBackgroundColorARGB
            let alphaByte = (argb >> 24) & 0xFF
            return UIColor(
                red: CGFloat((argb >> 16) & 0xFF) / 255,
                green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255,
                alpha: alphaByte == 0 ? 1 : CGFloat(alphaByte) / 255
            )
        }

        let settings = UserDefaults.lyricsColors

        if settings.displayOriginalColors,
           let original = backgroundViewModel?.color() {
            return original.withAlphaComponent(1)
        }

        if settings.useStaticColor, !settings.staticColor.isEmpty {
            return UIColor(Color(hex: settings.staticColor))
        }

        if let hex = currentTrackExtractedColorHex() {
            return UIColor(Color(hex: hex).normalized(settings.normalizationFactor))
        }

        if let background = backgroundViewModel?.color() {
            return UIColor(Color(background).normalized(settings.normalizationFactor))
                .withAlphaComponent(1)
        }

        return .gray
    }

    private func currentTrackExtractedColorHex() -> String? {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14:
            return track?.extractedColorHex()
        default:
            return track?.metadata()["extracted_color"]
        }
    }

    // MARK: 手动滚动打断自动跟随

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        autoScrollPauseUntil = Date().addingTimeInterval(3)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 歌词滚到顶部/底部时对应渐隐层才隐藏（保证首尾行不被遮挡）
        updateFadeVisibility()
    }

    /// 顶部渐隐在歌词未滚动（在顶部）时隐藏，保证第一行不被遮挡；
    /// 底部渐隐在歌词滚到底部时隐藏，保证最后一行/提供者不被遮挡。
    private func updateFadeVisibility() {
        let atTop = scrollView.contentOffset.y <= 1
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let atBottom = scrollView.contentOffset.y >= maxY - 1
        topFadeView.isHidden = stackView.isHidden || atTop
        bottomFadeView.isHidden = stackView.isHidden || atBottom
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        autoScrollPauseUntil = Date().addingTimeInterval(2)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        autoScrollPauseUntil = Date().addingTimeInterval(2)
    }

    private func scrollToLine(_ lineIndex: Int) {
        // 手动滚动暂停期内不自动拉回
        guard Date() >= autoScrollPauseUntil else { return }
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        // 强制刷新布局：初次挂载/rebuild 后 contentSize 与各行 frame 尚未更新，
        // 不刷新会按旧 contentSize 算出错误 target，导致全屏打开时不滚到当前行。
        scrollView.layoutIfNeeded()
        let label = lineLabels[lineIndex]
        let rect = label.convert(label.bounds, to: scrollView)
        // 当前行定位到视口上方约 1/3 处，而不是 scrollRectToVisible 那样贴到最底部。
        let targetY = rect.minY - scrollView.bounds.height * activeLineViewportFraction
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let target = CGPoint(x: 0, y: min(max(0, targetY), maxY))
        // 自定义更短的动画时长，让自动滚动更干脆（贴近 Spotify 手感）
        UIView.animate(
            withDuration: scrollAnimationDuration,
            delay: 0,
            options: [.curveEaseOut],
            animations: { [weak self] in
                self?.scrollView.setContentOffset(target, animated: false)
            }
        )
    }

    /// 滚回歌词顶部（含安全区内边距修正）。
    private func scrollToTop() {
        scrollView.setContentOffset(
            CGPoint(x: 0, y: -scrollView.adjustedContentInset.top),
            animated: true
        )
    }

    @objc private func handleLineTap(_ recognizer: UITapGestureRecognizer) {
        guard let label = recognizer.view as? LineLabel,
              let dto = dto, label.lineIndex >= 0, label.lineIndex < dto.lines.count,
              let offset = dto.lines[label.lineIndex].offsetMs else { return }
        WordByWordSeeker.seek(toMs: offset)
    }
}

// MARK: - 挂载管理

final class WordByWordHost {
    static let shared = WordByWordHost()

    private var overlay: LyricsWordByWordOverlayView?
    private weak var hostView: UIView?
    private var isAttached = false
    /// 最近出现的内嵌歌词 VC（弱引用），全屏关闭后据此重新挂载。
    private weak var lastInlineController: UIViewController?

    func rememberInlineController(_ controller: UIViewController) {
        lastInlineController = controller
    }

    func reattachToInline() {
        guard let controller = lastInlineController else { return }
        attach(to: controller, showsTranslation: false)
    }

    private var renderEnabled: Bool {
        NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
    }

    /// contentView: overlay 挂到哪个视图（默认 VC 的 view；全屏歌词挂到内容子视图）。
    /// keepAboveView: 需要保留在 overlay 之上的原生控件（全屏歌词的分享/更多按钮），必须是 contentView 的直接子视图。
    /// sideInset: 覆盖层歌词行的左右边距（全屏可用更大值，默认用 overlay 自己的）。
    /// showsProviderFooter: 是否在底部显示「歌词提供者」（全屏显示，内嵌不显示）。
    /// showsTranslation: 是否显示行级译文（全屏显示；内嵌「预览歌词」不显示）。
    func attach(
        to controller: UIViewController,
        contentView: UIView? = nil,
        keepAboveView: UIView? = nil,
        sideInset: CGFloat? = nil,
        showsProviderFooter: Bool = false,
        showsTranslation: Bool = true
    ) {
        guard renderEnabled else { return }
        let view = contentView ?? controller.view
        guard let view else { return }

        // 已挂在同一视图上则跳过；换视图（内嵌 ↔ 全屏切换）时先卸载旧的再挂新的。
        if isAttached, hostView === view { return }
        detach()

        let overlayView = LyricsWordByWordOverlayView(frame: view.bounds)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.showsProviderFooter = showsProviderFooter
        overlayView.showsTranslation = showsTranslation
        if let sideInset { overlayView.setSideInset(sideInset) }
        view.addSubview(overlayView)
        if let keepAboveView, keepAboveView.superview === view {
            // 保留原生控件栏在 overlay 之上（按钮仍可见可点）
            view.bringSubviewToFront(keepAboveView)
        } else {
            view.bringSubviewToFront(overlayView)
        }

        overlay = overlayView
        hostView = view
        isAttached = true

        WordByWordPlaybackClock.shared.onChange = { [weak overlayView] ms in
            overlayView?.setCurrentTime(ms)
        }
        WordByWordPlaybackClock.shared.start()
        writeDebugLog("[WordByWord] overlay attached")
    }

    func detach() {
        guard isAttached else { return }
        WordByWordPlaybackClock.shared.stop()
        WordByWordPlaybackClock.shared.onChange = nil
        overlay?.removeFromSuperview()
        overlay = nil
        hostView = nil
        isAttached = false
        writeDebugLog("[WordByWord] overlay detached")
    }
}

// MARK: - 挂载 hook（全屏歌词 VC）

class LyricsWordByWordModernHostHook: ClassHook<UIViewController> {
    typealias Group = ModernLyricsGroup
    static let targetName = "Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        WordByWordHost.shared.rememberInlineController(vc)
        DispatchQueue.main.async {
            WordByWordHost.shared.attach(to: vc, showsTranslation: false)
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        WordByWordHost.shared.detach()
    }
}

class LyricsWordByWordLegacyHostHook: ClassHook<UIViewController> {
    typealias Group = LegacyLyricsGroup
    static let targetName = "Lyrics_CoreImpl.LyricsOnlyViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        WordByWordHost.shared.rememberInlineController(vc)
        DispatchQueue.main.async {
            WordByWordHost.shared.attach(to: vc, showsTranslation: false)
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        WordByWordHost.shared.detach()
    }
}

// MARK: - 全屏歌词挂载 hook（点击歌词框架展开后铺满的页面）

class LyricsWordByWordFullscreenModernHostHook: ClassHook<UIViewController> {
    typealias Group = ModernLyricsGroup
    static let targetName = "Lyrics_FullscreenElementPageImpl.FullscreenElementViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        DispatchQueue.main.async {
            // 只覆盖「歌词内容」子模块 LyricsView（已由层级 dump 确认，frame=0,104 414x570）；
            // 页面其余部分（标题 HeaderView、按钮 ControlsView、进度条 FooterView）保持原生
            let contentView: UIView = WindowHelper.shared.findFirstSubview(
                "Lyrics_FullscreenElementPageImpl.LyricsView", in: vc.view
            ) ?? vc.view
            // 全屏左边距用 24（贴近 Spotify 原生歌词内容的 24pt 内缩），比内嵌的 16 更靠右
            WordByWordHost.shared.attach(to: vc, contentView: contentView, sideInset: 24, showsProviderFooter: true)
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        WordByWordHost.shared.detach()
        // 全屏以 sheet 形式盖在内嵌之上，关闭时内嵌 VC 不会重新 viewDidAppear；
        // 用记住的内嵌 VC 把 overlay 挂回去。
        WordByWordHost.shared.reattachToInline()
    }
}

class LyricsWordByWordFullscreenLegacyHostHook: ClassHook<UIViewController> {
    typealias Group = LegacyLyricsGroup
    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.FullscreenViewController"
        default: return "Lyrics_FullscreenPageImpl.FullscreenViewController"
        }
    }

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        DispatchQueue.main.async {
            // 把原生 headerView（分享/举报按钮）保留在 overlay 之上；
            // iOS14/15 的歌词内容子模块等层级 dump 后再改为只覆盖内容区
            let header = Ivars<UIView>(vc.view).headerView
            WordByWordHost.shared.attach(to: vc, keepAboveView: header, sideInset: 24, showsProviderFooter: true)
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        WordByWordHost.shared.detach()
        // 同 modern hook：关闭全屏时把 overlay 挂回内嵌歌词 VC
        WordByWordHost.shared.reattachToInline()
    }
}
