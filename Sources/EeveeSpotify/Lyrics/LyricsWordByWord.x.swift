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

    /// 供 Apple Music 渲染层使用的每帧回调。
    /// 与 `onChange` 互斥：挂载时只会设置其中一个。
    var tickHandler: ((Double) -> Void)?

    @objc private func tick() {
        let ms: Double
        if let seconds = WordByWordPositionResolver.shared.currentPositionSeconds() {
            ms = seconds * 1000
        } else {
            ms = currentMs
        }
        currentMs = ms
        onChange?(ms)
        tickHandler?(ms)
    }
}

// MARK: - 叠加视图

/// 逐字数据是否可用：至少一半的行有「多词」级时间轴（words.count >= 2）。
/// 整行一个词 / 全退化 / 词级时间轴错位 等坏数据会低于阈值，回退原生行级。
///
/// 抽成文件级函数是因为它有**两个**消费者：旧的 UIKit overlay（`setCurrentTime`）
/// 和 Apple Music 渲染层（挂载前判定）。判定口径必须一致。
func hasUsableWordLevelData(_ dto: LyricsDto?) -> Bool {
    guard let dto, dto.timeSynced else { return false }
    let lines = dto.lines
    guard !lines.isEmpty else { return false }
    let wordLevelLines = lines.filter { ($0.words?.count ?? 0) >= 2 }.count
    return wordLevelLines * 10 >= lines.count * 5  // >= 50%
}

private final class LineLabel: UILabel {
    var lineIndex = -1
}

final class LyricsWordByWordOverlayView: UIView, UIScrollViewDelegate {

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var lineLabels: [UILabel] = []
    private var displayTexts: [String] = []
    private var wordRanges: [[Range<String.Index>]] = []
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

    /// 行色随背景明暗切换，见 `resolveTextColors`。
    private var lineColor = UIColor.black
    private var activeLineColorValue = UIColor.white
    /// 行级译文字号（比歌词小）。
    private let translationFontSize: CGFloat = 16
    /// 行级译文颜色：与未唱歌词（其余行）一致。
    private var translationColor = UIColor.black
    /// 当前行内「未唱」词的透明度（已唱/正在唱为全白）。
    private let unsungWordOpacity: CGFloat = 0.45
    /// 背景色缓存：每次 rebuild（换歌/换数据）后按「定制」选项重新计算一次。
    private var resolvedBackgroundColor: UIColor?
    /// 模糊封面背景层（最底层）：封面拿不到 / 用户选了静态色时自动退回纯色。
    private let backdropView = LyricsBackdropView()
    /// 当前背景对应的「歌 + 设置」标识，变了才重新配置背景。
    private var resolvedBackdropKey: String?
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
    /// 当前行在视口中的目标位置（距顶部比例）：0.40 = 视口上方约 40% 处。
    private let activeLineViewportFraction: CGFloat = 0.40
    /// 自动滚动动画时长（秒），越小越「干脆」。
    private let scrollAnimationDuration: TimeInterval = 0.20
    /// 歌词行字号（对照 Spotify 原生歌词放大）。
    private let lyricsFontSize: CGFloat = 22
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

    /// 设置背景样式：全屏传 `.stage`（溢出铺满整屏、均匀暗化），
    /// 内嵌预览传 `.card`（只在卡片内、上下暗中间透）。
    func setBackdropStyle(_ style: LyricsBackdropView.Style) {
        backdropView.style = style
        // 样式变了要让 configureBackdropIfNeeded 重新算一次（它按 key 缓存）。
        resolvedBackdropKey = nil
    }

    /// 调整歌词行左右边距（全屏用到更大的左边距时调用）。
    func setSideInset(_ inset: CGFloat) {
        lyricsSideInset = inset
        stackLeadingConstraint?.constant = inset
        stackTrailingConstraint?.constant = -inset
        stackWidthConstraint?.constant = -(2 * inset)
    }

    private func setupView() {
        // 背景交给 backdropView（模糊封面），自身保持透明，否则会把它盖住。
        backgroundColor = .clear

        backdropView.frame = bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

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

        // 背景必须在最底层 —— 放在所有子视图添加完之后再插到 index 0，
        // 不依赖 addSubview 的调用顺序。
        insertSubview(backdropView, at: 0)
    }

    /// 每帧由时钟调用：惰性取 dto、词级高亮、自动滚动。
    func setCurrentTime(_ ms: Double) {
        if dtoVersion != currentLyricsVersion {
            dto = currentLyricsDto
            dtoVersion = currentLyricsVersion
            rebuild()
        }

        // 背景（模糊封面 + 暗化）与文字色必须先于下面的 guard 配置好：
        // 文字色取决于背景明暗，而 rebuild() 已经按旧色建过标签了。
        configureBackdropIfNeeded()

        // 只有「有足够多行真逐字 且 时间同步」才显示逐字；
        // 否则（无逐字 / 坏逐字 / 静态歌词 / 还没加载到 dto）一律透明 + 隐藏标签，回退 Spotify 原生。
        guard let dto, hasUsableWordLevelData(dto) else {
            backgroundColor = .clear
            backdropView.isHidden = true
            stackView.isHidden = true
            topFadeView.isHidden = true
            bottomFadeView.isHidden = true
            isUserInteractionEnabled = false   // 回退原生时让触摸穿透，别挡住原生歌词滚动
            return
        }

        stackView.isHidden = false
        isUserInteractionEnabled = true
        updateFadeVisibility()

        var bestLine = -1
        var bestWord = -1
        for (i, line) in dto.lines.enumerated() {
            guard let offset = line.offsetMs, Double(offset) <= ms else { continue }
            bestLine = i
            if let words = line.words {
                for j in words.indices where Double(words[j].startMs) <= ms {
                    bestWord = j
                }
            }
        }

        // 诊断：节流打印当前高亮状态（每 1s 一次），用于对比数据时间轴与实际渲染
        if Date().timeIntervalSince(lastDiagnosticLog) > 1.0 {
            lastDiagnosticLog = Date()
            var wordInfo = "no-line"
            if bestLine >= 0, bestLine < dto.lines.count {
                if let words = dto.lines[bestLine].words, !words.isEmpty {
                    if bestWord >= 0, bestWord < words.count {
                        wordInfo = "w\(bestWord)=\"\(words[bestWord].text)\"@\(words[bestWord].startMs)ms"
                    } else {
                        wordInfo = "w=none-yet"
                    }
                } else {
                    wordInfo = "words=nil"
                }
            }
            writeDebugLog("[WordByWord] t=\(Int(ms))ms line=\(bestLine) \(wordInfo)")
        }

        if bestLine == activeLineIndex && bestWord == activeWordIndex { return }

        let lineChanged = bestLine != activeLineIndex

        if lineChanged {
            let oldIndex = activeLineIndex
            activeLineIndex = bestLine

            if bestLine == oldIndex + 1 {
                // 正常前进：只更新旧/新两行，crossfade 平滑黑白切换，消除闪烁
                if oldIndex >= 0, oldIndex < lineLabels.count {
                    crossfade(lineLabels[oldIndex]) { self.applyPlain(to: oldIndex) }
                }
            } else {
                // 跳转/回退：整列表重涂 —— 已唱过/当前行白、未到行黑
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
        if bestLine >= 0 {
            if lineChanged {
                crossfade(lineLabels[bestLine]) { self.applyHighlight(to: bestLine, wordIndex: bestWord) }
            } else {
                applyHighlight(to: bestLine, wordIndex: bestWord)
            }
        }
    }

    private func rebuild() {
        for label in lineLabels { label.removeFromSuperview() }
        lineLabels = []
        for label in translationLabels { label.removeFromSuperview() }
        translationLabels = []
        providerLabel?.removeFromSuperview()
        providerLabel = nil
        displayTexts = []
        wordRanges = []
        wordIndices = []
        activeLineIndex = -1
        activeWordIndex = -1
        resolvedBackgroundColor = nil
        // 换歌/换数据后强制重算背景（即使两首歌底色恰好相同也要换封面）。
        resolvedBackdropKey = nil
        // 文字色不在这里定：setCurrentTime 紧接着就会调用
        // configureBackdropIfNeeded()，由它按背景明暗统一决定并在需要时重涂。
        // 这里先回到改动前的默认值，保证纯色兜底时建出来的标签就是对的。

        guard let dto else { return }

        for (index, line) in dto.lines.enumerated() {
            let (text, ranges, indices) = buildDisplayText(for: line)
            let label = LineLabel()
            label.lineIndex = index
            label.numberOfLines = 0
            label.textAlignment = .left
            label.font = .systemFont(ofSize: lyricsFontSize, weight: .semibold)
            label.text = text
            label.textColor = lineColor
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
            displayTexts.append(text)
            wordRanges.append(ranges)
            wordIndices.append(indices)
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
    }

    /// 由词文本拼出行显示文本，并记录每个词在文本中的范围（空格 token 保留，空文本词跳过）。
    private func buildDisplayText(for line: LyricsLineDto) -> (String, [Range<String.Index>], [Int]) {
        guard let words = line.words, !words.isEmpty else { return (line.content, [], []) }

        var text = ""
        var ranges: [Range<String.Index>] = []
        var indices: [Int] = []
        for (index, word) in words.enumerated() {
            guard !word.text.isEmpty else { continue }
            let start = text.endIndex
            text += word.text
            ranges.append(start..<text.endIndex)
            indices.append(index)
        }
        guard !text.isEmpty else { return (line.content, [], []) }
        return (text, ranges, indices)
    }

    /// 行切换时整列表重涂：已唱过/当前行白、未到行黑（Spotify 原生样式）。
    private func repaintAllLines(upTo activeIndex: Int) {
        for (index, label) in lineLabels.enumerated() {
            label.attributedText = nil
            label.text = displayTexts[index]
            label.textColor = index <= activeIndex ? activeLineColorValue : lineColor
        }
    }

    /// 把某一行重置为纯白（已唱状态）。
    private func applyPlain(to lineIndex: Int) {
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        let label = lineLabels[lineIndex]
        label.attributedText = nil
        label.text = displayTexts[lineIndex]
        label.textColor = activeLineColorValue
    }

    /// 用 crossfade 平滑某个 label 的外观切换（消除行切换时的整行闪烁）。
    private func crossfade(_ label: UILabel, _ update: @escaping () -> Void) {
        UIView.transition(with: label, duration: 0.15, options: [.transitionCrossDissolve], animations: update)
    }

    /// 当前行内部按「已唱/正在唱/未唱」上色（Apple Music 式行内点亮）：
    /// 已唱全白（普通）、正在唱全白加粗、未唱降透明度。
    private func applyHighlight(to lineIndex: Int, wordIndex: Int) {
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        let label = lineLabels[lineIndex]
        let text = displayTexts[lineIndex]

        let regularFont = UIFont.systemFont(ofSize: lyricsFontSize, weight: .semibold)

        // 整行默认全白（没有词级数据的行也保持全白）
        let highlighted = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: activeLineColorValue,
            .font: regularFont,
        ])

        let ranges = wordRanges[lineIndex]
        let indices = wordIndices[lineIndex]
        let activePos = wordIndex >= 0 ? indices.firstIndex(of: wordIndex) : nil

        for (pos, _) in indices.enumerated() {
            guard pos < ranges.count else { continue }
            let nsRange = NSRange(ranges[pos], in: text)

            let isSung = activePos.map { pos < $0 } ?? false
            if pos == activePos {
                // 正在唱：全白 + 描边"加粗"（负 strokeWidth 叠在填充上，不改变字形宽度，
                // 避免日文逐字加粗导致换行重排的闪烁）
                highlighted.addAttributes([
                    .strokeWidth: -2.0,
                    .strokeColor: activeLineColorValue,
                ], range: nsRange)
            } else if activePos != nil, !isSung {
                // 未唱：仅当已有正在唱的词时才降透明度；
                // 一行还没唱到第一个词时整行保持全白，避免「整行突然变灰」的闪烁
                highlighted.addAttributes([
                    .foregroundColor: activeLineColorValue.withAlphaComponent(unsungWordOpacity),
                ], range: nsRange)
            }
            // 已唱（pos < activePos）：保持整行默认的全白
        }

        label.attributedText = highlighted
    }

    // MARK: 背景：模糊封面

    /// 是否使用「模糊封面 + 暗化渐变」背景。三条否决：
    ///   - 用户在「定制」里选了静态色 → 静态色优先，不做封面背景；
    ///   - 用户选了显示原生颜色 → 保持 Spotify 原始观感，不做封面背景；
    ///   - 开关本身关掉 → 退回改动前的纯色底。
    private var backdropEnabled: Bool {
        guard NgzhwmSettingsViewModel.isLyricsBlurredBackdropEnabled else { return false }
        let settings = UserDefaults.lyricsColors
        if settings.useStaticColor, !settings.staticColor.isEmpty { return false }
        if settings.displayOriginalColors { return false }
        return true
    }

    /// 背景配置的缓存标识：换歌、改设置、或底色来源变化都会让它变化。
    /// 返回 nil 表示当前应使用纯色底。
    ///
    /// 把 `currentLyricsBackgroundColorARGB` 也编进去是必要的：CustomLyrics
    /// 是在歌词注入**之后**才写回这个值，只按歌名做 key 会一直用首次算出的底色。
    private func backdropKey() -> String? {
        guard backdropEnabled else { return nil }
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        let trackKey = track?.trackIdentifier ?? "unknown"
        return "\(trackKey)|\(NgzhwmSettingsViewModel.isLyricsBackdropMaterialEnabled)|\(currentLyricsBackgroundColorARGB)"
    }

    /// 按当前背景明暗决定文字色。
    ///
    /// `isDarkSurface` 为 nil 表示「当前是纯色兜底底」，此时沿用改动前的黑底约定；
    /// 非 nil 时表示模糊封面层正在生效（该层必然是深色，因为有暗化渐变），
    /// 而原来的行色是按 Spotify 浅色底定的黑字 —— 不切换未唱行与译文会直接看不见。
    ///
    /// ⚠️ 这里显式传参而不是读 `backdropView.isHidden`：后者会残留上一次的底色判断，
    /// 在「切歌后先走纯色、再切到模糊封面」这种过渡帧上会做出错误结论。
    ///
    /// 返回 true 表示文字色发生了变化（调用方据此决定要不要重涂标签）。
    @discardableResult
    private func resolveTextColors(isDarkSurface: Bool?) -> Bool {
        // 已唱/正在唱始终是最亮的一层，两种底色下都是白色。
        let newLineColor: UIColor
        let newTranslationColor: UIColor
        if let isDarkSurface {
            // 深底：未唱用白（靠 unsungWordOpacity 压暗，与已唱区分），译文白但略淡。
            // 浅底：维持改动前的黑字。
            newLineColor = isDarkSurface ? .white : .black
            newTranslationColor = isDarkSurface ? UIColor.white.withAlphaComponent(0.75) : .black
        } else {
            newLineColor = .black
            newTranslationColor = .black
        }

        let changed = newLineColor != lineColor || newTranslationColor != translationColor
        lineColor = newLineColor
        translationColor = newTranslationColor
        activeLineColorValue = .white
        return changed
    }

    /// 按需（重）配置背景：纯色底或模糊封面层，并同步文字色。
    ///
    /// 每帧调用，但只在「首次 / 换歌 / 改设置 / 底色来源变化」时真正干活。
    private func configureBackdropIfNeeded() {
        // ── 非卡拉 OK 状态：**整块透明，把屏幕交还给 Spotify 原生界面** ──────────
        //
        // 什么时候走到这里：逐词歌词关掉、或这一首歌没有可用的词级时间轴。
        // 此时这一层不该画任何东西 —— 连背景也不该画。
        //
        // ⚠️ 这里以前会铺一块**不透明的底色**（`backgroundColor = targetBackground`）。
        // 那一块把 Spotify 原生那一页整个盖住了：标题栏、进度条、播放键全部被压掉，
        // 屏幕上只剩我们的歌词和一块专辑色 —— 也就是"关掉更好的逐词歌词之后
        // 界面全没了"的真正原因。
        //
        // 而这一层本来的设计意图就是"渲染不了就交还"（见下面 `setCurrentTime` 里
        // 那个 guard 的注释）。不透明底色把这个退路堵死了。现在补回来。
        guard NgzhwmSettingsViewModel.isWordByWordLyricsEnabled,
              hasUsableWordLevelData(currentLyricsDto) else {
            backgroundColor = .clear
            backdropView.isHidden = true
            return
        }

        // resolvedBackgroundColor 是缓存，用户改「定制」里的颜色时它不会变，
        // 所以不能沿用旧的 `backgroundColor != targetBackground` 判断，
        // 要把影响外观的几项一起编进 key。
        let key = backdropKey()
        let changed = resolvedBackgroundColor == nil || resolvedBackdropKey != key
        let targetBackground = changed ? overlayBackgroundColor() : (resolvedBackgroundColor ?? .black)

        if changed {
            resolvedBackgroundColor = targetBackground
            resolvedBackdropKey = key
        }

        // 纯色底（用户选了静态色 / 显示原生色 / 开关关闭）：整块退回改动前的行为。
        guard key != nil else {
            if changed {
                backdropView.isHidden = true
                backgroundColor = targetBackground
                topFadeLayer.colors = [
                    targetBackground.cgColor,
                    targetBackground.withAlphaComponent(0).cgColor
                ]
                bottomFadeLayer.colors = [
                    targetBackground.withAlphaComponent(0).cgColor,
                    targetBackground.cgColor
                ]
            }
            // 纯色兜底：沿用改动前的黑字约定（传 nil）。
            if resolveTextColors(isDarkSurface: nil) {
                repaintAllLines(upTo: activeLineIndex)
            }
            return
        }

        // 文字色跟着背景明暗走 —— 模糊封面层必然是深色底，而默认行色是黑字。
        // 每帧都能安全调用：resolveTextColors 是恒等操作，除非颜色真的要变。
        if changed {
            backdropView.isHidden = false
            backdropView.configure(
                baseColor: targetBackground,
                showsArtwork: true,
                material: NgzhwmSettingsViewModel.isLyricsBackdropMaterialEnabled
            )
            // 渐变遮罩仍用纯色：它只负责让滚进/滚出视口的歌词渐隐，用底色即可。
            let fadeBase = resolvedBackgroundColor ?? targetBackground
            topFadeLayer.colors = [
                fadeBase.cgColor,
                fadeBase.withAlphaComponent(0).cgColor
            ]
            bottomFadeLayer.colors = [
                fadeBase.withAlphaComponent(0).cgColor,
                fadeBase.cgColor
            ]
            // 自身保持透明，否则会把 backdropView 盖住。
            backgroundColor = .clear
        }

        if resolveTextColors(isDarkSurface: backdropView.baseColorBrightness < 0.55) {
            repaintAllLines(upTo: activeLineIndex)
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

/// `@MainActor`：整个挂载链路只碰 UIKit（往 VC 的视图上挂 overlay），而调用点
/// （VC 的 viewDidAppear / SwiftUI 手势）本来都在主线程。标出来是为了让
/// `AppleMusicLyricsOverlayHost` 这个同样 main-actor 隔离的单例能被合法调用 ——
/// 否则就是"在非隔离同步上下文调用 MainActor 隔离的方法"。
@MainActor
final class WordByWordHost {
    static let shared = WordByWordHost()

    private var overlay: LyricsWordByWordOverlayView?
    private weak var hostView: UIView?
    private var isAttached = false
    /// 最近出现的内嵌歌词 VC（弱引用），全屏关闭后据此重新挂载。
    private weak var lastInlineController: UIViewController?
    /// 关闭全屏时留在原宿主上的静态替身（见 `handOffToInlineKeepingStandIn`）。
    private var transitionStandInView: UIView?

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

    /// contentView: overlay 挂到哪个视图（默认 VC 的 view）。
    /// sideInset: 覆盖层歌词行的左右边距（全屏可用更大值，默认用 overlay 自己的）。
    /// showsProviderFooter: 是否在底部显示「歌词提供者」（全屏显示，内嵌不显示）。
    /// showsTranslation: 是否显示行级译文（全屏显示；内嵌「预览歌词」不显示）。
    ///
    /// 这里曾经还有一个 `keepAboveView`（把原生 header 抬到 overlay 之上）。
    /// 已删除：它依赖"原生控件是本视图的直接子视图"这个**不成立**的假设，
    /// 而且取 header 用的 `Ivars` 在 Modern 全屏页上会命中不存在的 ivar（崩）。
    /// 旧 overlay 的显隐现在完全由"有没有逐词数据"决定，不需要它。
    func attach(
        to controller: UIViewController,
        contentView: UIView? = nil,
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

        let sideInset = sideInset ?? 16
        let usable = hasUsableWordLevelData(currentLyricsDto)

        // 系统版本够、开关打开、数据可用 → 走 Apple Music 渲染层。
        // 三个条件缺一就走下面的 UIKit 旧实现，行为与改动前完全一致。
        if #available(iOS 26.0, *),
           usable,
           NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled {
            // ⚠️ 这里**不碰任何原生视图**：不隐藏、不清底色、不动 z 序。
            //
            // 全屏页曾经被这么"接管"过，结果是整页空白（真机 + dump 双证）：
            //   · 隐藏 `Lyrics_FullscreenElementPageImpl.LyricsView` →
            //     全屏页根视图里**一个子视图都没有**（dump 实测），
            //     Spotify 那一页的 header / 歌词 / 控件栏都不在根视图这一层，
            //     所以"藏歌词容器"等于把整页内容一起藏了；
            //   · 清根视图的 `backgroundColor` / layer → 摘掉的是这一页唯一的背景层
            //     （dump: `stripped 1 background layer(s): CALayer`），页面连底都没了。
            //
            // 现在的策略：原生 UI 全部原样保留，我们只负责把自己那块背景做够暗，
            // 让它盖住底下的东西（`LyricsBackdropView.solidStageScrimAlpha`）。
            // 这个判据用的是 showsProviderFooter —— 它只在全屏页为 true。
            // ── 挂载点：预览挂到**卡片容器**上，自己出壳 ─────────────────────
            //
            // 预览卡片的"壳"（顶部 `歌词` + 分享/展开那一行、四周留白）是 Spotify 的
            // Element 框架画的，而我们的层原来是挂在**歌词视图**（卡片里的一块内容）上。
            // 子视图盖不住父视图自己的背景，所以那一行 39pt 永远是专辑纯色 ——
            // 试过五种"盖住它"的办法（塞背景层 / 清容器底色 / 每帧重清 /
            // 画出 bounds 之外 / 改注入的背景色）全部无效，原因就在这。
            //
            // 现在换思路：把我们的层挂到**卡片容器**上、铺满整张卡片。
            // 壳这一层从此由我们画（`previewHeader` 就是那一行），粉杠问题不复存在。
            //
            // 全屏不受影响：它本来就挂 vc.view，并且自己画了整套壳。
            let mountView = showsProviderFooter ? view : (Self.cardContainer(for: view) ?? view)
            // 卡片比歌词视图高出来的那段（实测 39pt）= 我们自绘标题栏要占的高度。
            // 全屏传 62（曲名 + 歌手两行，与页面默认值一致）。
            let headerInset = showsProviderFooter
                ? 62
                : max(mountView.bounds.height - view.bounds.height, 0)
            AppleMusicLyricsOverlayHost.shared.update(
                in: mountView,
                sideInset: sideInset,
                showsProviderFooter: showsProviderFooter,
                solidBackdrop: showsProviderFooter,
                previewHeaderInset: headerInset
            )
            // 预览：把"展开 / 分享"的全部候选控件（标签 + frame）打一次日志。
            //
            // 为什么要这个：真机上出现过"点我们画的小方框没反应、点 `歌词` 两个字
            // 反而能进全屏"。那说明 `expandToFullscreenLyrics()` 找到的控件**不是**
            // 卡片上那一颗（很可能是页面别处的同名按钮，位置完全不同）。
            // 有了候选清单，就能按"在卡片范围内"来挑，不必再猜。
            if !showsProviderFooter {
                WordByWordPlaybackControl.dumpPreviewActionCandidates()
            }
            // 新层由主时钟驱动，旧 overlay 的回调必须清掉，否则两边同时渲染。
            WordByWordPlaybackClock.shared.onChange = nil
            WordByWordPlaybackClock.shared.tickHandler = { @MainActor ms in
                AppleMusicLyricsOverlayHost.shared.tick(ms: ms)
            }
            WordByWordPlaybackClock.shared.start()
            hostView = view
            isAttached = true
            return
        }

        // 用不上新层就把它摘掉（例如从有逐字的歌切到纯 LRC 的歌）。
        if #available(iOS 26.0, *) {
            AppleMusicLyricsOverlayHost.shared.detach()
        }

        // 数据不可用时保持原生歌词，不做任何覆盖：
        // 铺一层空白背景比直接放行原生渲染更糟。
        guard usable else { return }

        let overlayView = LyricsWordByWordOverlayView(frame: view.bounds)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.showsProviderFooter = showsProviderFooter
        overlayView.showsTranslation = showsTranslation
        // 全屏时背景改成"舞台式"：溢出到容器之外铺满整屏、均匀暗化。
        // 目的是让 Spotify 原有的 header / 控件栏和歌词落在同一块背景上，
        // 消除"品红壳 / 暗色肉"的割裂。内嵌预览保持卡片式。
        overlayView.setBackdropStyle(showsProviderFooter ? .stage : .card)
        overlayView.setSideInset(sideInset)
        view.addSubview(overlayView)
        // 挂到最前。
        //
        // ⚠️ 这个 `bringSubviewToFront` 与"会不会盖住 Spotify 原生界面"**无关** ——
        // 原生那一页（`ElementView`）不在这条视图链上，抬谁的层级都影响不到它。
        // 会不会盖住，只取决于这一层自己画不画东西：
        //   · 有逐词数据 → 画歌词 + 背景，此时理应盖住原生歌词（我们替换了它）；
        //   · 没有 → `configureBackdropIfNeeded` 与 `setCurrentTime` 的 guard 会把
        //     整层变透明并让触摸穿透，原生界面与控件原样可用。
        view.bringSubviewToFront(overlayView)

        overlay = overlayView
        hostView = view
        isAttached = true

        // 旧 overlay 的时间回调（新层走 `tickHandler`，两者互斥）。
        //
        // ⚠️ 两个闭包都显式标 `@MainActor`：它们的目标
        // （`AppleMusicLyricsOverlayHost.tick`、`LyricsWordByWordOverlayView.setCurrentTime`）
        // 都是 main-actor 隔离的，而在 `attach`（已隔离）里创建的闭包**不会自动继承**
        // 隔离 —— 不标就是"在非隔离同步上下文调用 MainActor 隔离方法"。
        // 运行时无变化：时钟是 `CADisplayLink` 挂在 `.main` run loop 上的，本来就在主线程。
        WordByWordPlaybackClock.shared.onChange = { @MainActor [weak overlayView] ms in
            overlayView?.setCurrentTime(ms)
        }
        WordByWordPlaybackClock.shared.tickHandler = nil
        WordByWordPlaybackClock.shared.start()
        writeDebugLog("[WordByWord] overlay attached")
    }

    func detach() {
        guard isAttached else { return }
        WordByWordPlaybackClock.shared.stop()
        WordByWordPlaybackClock.shared.onChange = nil
        WordByWordPlaybackClock.shared.tickHandler = nil
        if #available(iOS 26.0, *) {
            AppleMusicLyricsOverlayHost.shared.detach()
        }
        overlay?.removeFromSuperview()
        overlay = nil
        hostView = nil
        isAttached = false
        writeDebugLog("[WordByWord] overlay detached")
    }

    // MARK: 关闭全屏的「静态替身」交接（C2）

    /// 关闭全屏时用：先给当前层拍一张**静态替身**留在原宿主（全屏页）上，
    /// 再把真正的 overlay 搬回内嵌卡片。
    ///
    /// 为什么必须这样：一个 overlay 视图没法同时挂在两个宿主上。直接在
    /// `viewWillDisappear` 里 `detach()` 的话，整段下滑动画期间全屏页露出的都是
    /// **Spotify 原生歌词 + 纯专辑色背景** —— 这就是"关闭时一闪"的成因。
    /// 留一张 `snapshotView` 顶替它在原位置的画面之后：
    ///   · 全屏页在整段关闭动画里仍是"我们的样子"（静态，但页面本来就在往下滑，看不出来）；
    ///   · 真正的层已经挂回内嵌卡片，卡片被露出来时也已经是我们的渲染。
    func handOffToInlineKeepingStandIn() {
        installStandIn()
        detach()
        reattachToInline()
    }

    /// 全屏页彻底消失后清掉替身。
    func removeStandIn() {
        guard let standIn = transitionStandInView else { return }
        standIn.removeFromSuperview()
        transitionStandInView = nil
        writeDebugLog("[Shell] stand-in removed")
    }

    /// 当前正在显示的那一层（Apple Music 层优先）。
    private var currentOverlayView: UIView? {
        if #available(iOS 26.0, *),
           let view = AppleMusicLyricsOverlayHost.shared.overlayView {
            return view
        }
        return overlay
    }

    // MARK: 预览卡片容器

    /// 预览卡片的容器：从歌词视图往上找第一个**比它高**的祖先。
    ///
    /// 为什么按"更高"而不是按类名：日志实测那两层是
    /// `Lyrics_NPVCommunicatorImpl.CardView(374x300)` ← 歌词视图 `(374x261)`，
    /// 差 39pt 正好是卡片顶部标题栏那一行。用尺寸关系判断比写死类名稳 ——
    /// 类名会随版本变，而"卡片比里面的歌词内容高"这个关系不会。
    ///
    /// 找不到就返回 nil（调用方退回原挂载点，不至于完全不工作）。
    static func cardContainer(for view: UIView) -> UIView? {
        var current: UIView? = view.superview
        var depth = 0
        // 只往上找 4 层：再往上就是滚动容器（cell / collection view），挂那儿就出界了。
        while let node = current, depth < 4 {
            if node.bounds.height > view.bounds.height + 0.5,
               node.bounds.width >= view.bounds.width - 0.5 {
                writeDebugLog(
                    "[PreviewShell] card container="
                        + "\(NSStringFromClass(type(of: node)))"
                        + " \(Int(node.bounds.width))x\(Int(node.bounds.height))"
                        + " lyrics=\(Int(view.bounds.width))x\(Int(view.bounds.height))"
                )
                return node
            }
            current = node.superview
            depth += 1
        }
        writeDebugLog("[PreviewShell] ⚠️ no card container found — falling back to lyrics view")
        return nil
    }

    private func installStandIn() {
        removeStandIn()

        guard let host = hostView,
              let current = currentOverlayView,
              let snapshot = current.snapshotView(afterScreenUpdates: false) else {
            writeDebugLog("[Shell] ⚠️ stand-in unavailable (no host / view / snapshot)")
            return
        }

        // 与原层同位置、同层级：插在它上面，就等于接替了它原来占的那一层
        // （原生控件在我们之上，替身也在我们之上，层级关系不变）。
        snapshot.frame = current.frame
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.isUserInteractionEnabled = false
        host.insertSubview(snapshot, aboveSubview: current)
        transitionStandInView = snapshot
        writeDebugLog("[Shell] stand-in installed for dismissal")
    }
}

// MARK: - 挂载 hook（全屏歌词 VC）
//
// ⚠️⚠️ **绝对不要在这些覆写方法（或 hook 类）上写 `@MainActor`。**
//
// Orion 的代码生成器是按**源码文本**拼接的：给覆写方法加 `@MainActor`，生成的
// `EeveeSpotify.xc.swift` 里会拼出 `@MainActoroverride` 这种非法属性，`override`
// 关键字也一起丢掉，整个文件报一串语法错误；而且它生成的 C 跳板是非隔离的，
// 同步调用被标成 `@MainActor` 的方法又构成隔离违规。
//
// 正确的写法：方法保持非隔离，**在方法体里**用 `onMainThreadSync { }`
// （定义在 `LyricsChromeVisibility.swift`）把"这是主线程"表达出来。
// 它已经是主线程时是同步执行的，不改变任何时序；`viewWillDisappear` 里的清理
// 因此仍然是同步的。
//
// 顺带：**内嵌（预览）**那两处沿用原有的 `DispatchQueue.main.async` 延后一拍再挂载，
// 写在 `onMainThreadSync` 里面；**全屏**那两处已改到 `viewWillAppear` 里直接挂 ——
// 多拖一拍会让转场动画期间露出 Spotify 自己的全屏歌词（"进入时一闪"）。

class LyricsWordByWordModernHostHook: ClassHook<UIViewController> {
    typealias Group = ModernLyricsGroup
    static let targetName = "Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            WordByWordHost.shared.rememberInlineController(vc)
            DispatchQueue.main.async {
                WordByWordHost.shared.attach(to: vc, showsTranslation: false)
            }
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            WordByWordHost.shared.detach()
        }
    }
}

class LyricsWordByWordLegacyHostHook: ClassHook<UIViewController> {
    typealias Group = LegacyLyricsGroup
    static let targetName = "Lyrics_CoreImpl.LyricsOnlyViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            WordByWordHost.shared.rememberInlineController(vc)
            DispatchQueue.main.async {
                WordByWordHost.shared.attach(to: vc, showsTranslation: false)
            }
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            WordByWordHost.shared.detach()
        }
    }
}

// MARK: - 全屏歌词挂载 hook（点击歌词框架展开后铺满的页面）

class LyricsWordByWordFullscreenModernHostHook: ClassHook<UIViewController> {
    typealias Group = ModernLyricsGroup
    static let targetName = "Lyrics_FullscreenElementPageImpl.FullscreenElementViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        let vc = target
        // 挂载点：**整屏的 vc.view**，除此之外什么都不做。
        //
        // 这里曾经把 overlay 挂到「歌词内容」子模块
        // `Lyrics_FullscreenElementPageImpl.LyricsView`（frame=0,104 414x570），
        // 后果是背景只能铺在 570pt 的容器内、容器边界上留一道"壳 / 肉"接缝 ——
        // 这是要消除的东西，所以改成挂整屏。
        //
        // ⚠️ 但"挂整屏"必须配上"不碰原生视图"。中间我试过更激进的一版
        // （隐藏歌词容器 + 把整层插到最底 + 清宿主底色），真机结果是**整页空白、
        // Spotify 菜单全没了**。原因见 `attach` 里的说明：这一页的 header / 歌词 /
        // 控件栏都不是 vc.view 的直接子视图，藏一个就等于藏整页。
        // 所以现在：原生 UI 一个都不动，靠我们自己的背景够暗来盖住它。
        // 全屏左边距用 24（贴近 Spotify 原生歌词内容的 24pt 内缩）
        //
        // ⚠️ 时机从 `viewDidAppear` 提前到 `viewWillAppear`：前者是**转场动画播完**
        // 才回调的，所以之前整段上滑动画期间露出的都是 Spotify 自己的全屏歌词
        // （纯专辑色背景 + 原生歌词），动画结束我们的层才贴上去 —— 就是"进入时一闪"。
        // 同时去掉 `DispatchQueue.main.async` 那一拍：它原本是"等布局"，而这一层的
        // 约束贴死 vc.view 四边，布局变化会自动跟随，不需要等。
        onMainThreadSync {
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            // 兜底：万一 viewWillAppear 时逐词数据还没就绪（歌词仍在路上），这里再挂一次。
            // 已经挂在同一宿主上时 `attach` 会直接 return，不会闪。
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            // 全屏以 sheet 形式盖在内嵌之上，关闭时内嵌 VC 不会重新 viewDidAppear；
            // 用记住的内嵌 VC 把 overlay 挂回去。
            //
            // C2：交接前先在全屏页上留一张静态替身 —— 否则整段下滑动画期间露出的
            // 是 Spotify 原生歌词 + 纯专辑色背景，也就是"关闭时一闪"。
            WordByWordHost.shared.handOffToInlineKeepingStandIn()
        }
    }

    func viewDidDisappear(_ animated: Bool) {
        orig.viewDidDisappear(animated)
        onMainThreadSync {
            // 关闭动画结束，替身可以撤掉了。
            WordByWordHost.shared.removeStandIn()
        }
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

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        let vc = target
        // 挂到 vc.view（整屏）。
        //
        // ⚠️ 这里以前会取 `Ivars<UIView>(vc.view).headerView` 并当作
        // `keepAboveView` 传下去，想让原生 header 浮在我们的 overlay 之上。
        // 那个做法已被证伪，参数整个删掉了：
        //   · Modern 全屏页上根本没有这个 ivar（`Ivars` 访问不存在的 ivar 是会崩的，
        //     靠的只是"老版本上恰好存在"这种运气）；
        //   · 就算取到，原生控件也不在这条视图链上，抬层级影响不到它们。
        //
        // 现在旧 overlay 的显隐完全由"有没有逐词数据"决定：有就画（盖住原生歌词），
        // 没有就整层透明 + 触摸穿透（原生界面与控件原样可用）。
        //
        // ⚠️ 时机从 `viewDidAppear` 提前到 `viewWillAppear`（同 modern hook）：
        // 避免转场动画期间露出 Spotify 自己的全屏歌词。
        onMainThreadSync {
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            // 兜底重挂：已经挂在同一宿主上时 `attach` 会直接 return。
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            // 同 modern hook：留静态替身 + 把 overlay 挂回内嵌歌词 VC。
            WordByWordHost.shared.handOffToInlineKeepingStandIn()
        }
    }

    func viewDidDisappear(_ animated: Bool) {
        orig.viewDidDisappear(animated)
        onMainThreadSync {
            WordByWordHost.shared.removeStandIn()
        }
    }
}
