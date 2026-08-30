import Orion
import UIKit
import ObjectiveC

// MARK: - 逐字歌词渲染模块（MVP）
//
// 结构：
//   KaraokePositionResolver — 安全多策略定位播放进度（运行时探测，responds/ivar 检查后再读，绝不裸调）
//   KaraokePlaybackClock   — CADisplayLink 时钟，把进度喂给叠加视图
//   LyricsKaraokeOverlayView — UIKit 叠加视图：逐行 UILabel + 当前词 NSAttributedString 高亮 + 自动滚动
//   KaraokeHost            — 挂载/卸载 overlay（挂在 Spotify 全屏歌词 VC 上）
//
// 前提（来自 Spotify 二进制逆向）：
//   进度候选：playbackPosition(Double)、currentPlaybackTime(Double)、currentTrackTimeSecs(Int64 秒)
//   挂载点：Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController（新版）/ Lyrics_CoreImpl.LyricsOnlyViewController（iOS14）
//   开关：复用 ngzhwm_wordByWordLyrics

var currentLyricsDto: LyricsDto?
var currentLyricsVersion: Int = 0

// MARK: - 位置解析

@objc protocol KaraokePositionDoubleGetter { func playbackPosition() -> Double }
@objc protocol KaraokeCurrentPlaybackTimeDoubleGetter { func currentPlaybackTime() -> Double }
@objc protocol KaraokeCurrentTrackTimeSecsGetter { func currentTrackTimeSecs() -> Int64 }
@objc protocol KaraokePlayerPositionGetter { func position() -> Double }
@objc protocol KaraokeSeekProtocol { func seekTo(_ seconds: Double) }

final class KaraokePositionResolver {
    static let shared = KaraokePositionResolver()

    private var getter: (() -> Double)?
    private(set) var sourceLabel: String = "unresolved"
    private var sampleCount = 0
    private var didLogUnresolved = false

    /// 逐策略探测：先试方法（responds 检查后 Dynamic.convert 调用），再试 ivar（class_getInstanceVariable 检查后读取）。
    /// 任一环节检查不通过就跳过，保证永不因猜错签名崩溃。
    func resolve() {
        // 首选：statefulPlayer.position() —— 已由 runtime dump 确认（d16@0:8 = double 无参，秒）
        if let p = statefulPlayer as? NSObject, p.responds(to: Selector("position")) {
            let g = Dynamic.convert(p, to: KaraokePlayerPositionGetter.self)
            getter = { g.position() }
            sourceLabel = "statefulPlayer.position() -> Double"
            writeDebugLog("[Karaoke] position source: \(sourceLabel)")
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
                let g = Dynamic.convert(obj, to: KaraokePositionDoubleGetter.self)
                getter = { g.playbackPosition() }
                sourceLabel = "\(label).playbackPosition() -> Double"
                writeDebugLog("[Karaoke] position source: \(sourceLabel)")
                return
            }
        }
        for (label, obj) in candidates {
            if obj.responds(to: Selector("currentPlaybackTime")) {
                let g = Dynamic.convert(obj, to: KaraokeCurrentPlaybackTimeDoubleGetter.self)
                getter = { g.currentPlaybackTime() }
                sourceLabel = "\(label).currentPlaybackTime() -> Double"
                writeDebugLog("[Karaoke] position source: \(sourceLabel)")
                return
            }
        }
        for (label, obj) in candidates {
            if let value = ivarInt64(obj, "currentTrackTimeSecs") {
                getter = { Double(value) }
                sourceLabel = "\(label).currentTrackTimeSecs -> Int64(秒)"
                writeDebugLog("[Karaoke] position source: \(sourceLabel)")
                return
            }
            if let value = ivarDouble(obj, "playbackPosition") {
                getter = { value }
                sourceLabel = "\(label).playbackPosition ivar -> Double"
                writeDebugLog("[Karaoke] position source: \(sourceLabel)")
                return
            }
        }
        if !didLogUnresolved {
            didLogUnresolved = true
            writeDebugLog("[Karaoke] no position source resolved — will retry on next tick")
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
            writeDebugLog("[Karaoke] pos sample \(sampleCount): \(raw)")
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

final class KaraokeSeeker {
    static func seek(toMs ms: Int) {
        guard let player = statefulPlayer as? NSObject, player.responds(to: Selector("seekTo:")) else {
            writeDebugLog("[Karaoke] seekTo: unavailable on statefulPlayer")
            return
        }
        let g = Dynamic.convert(player, to: KaraokeSeekProtocol.self)
        g.seekTo(Double(ms) / 1000)
        writeDebugLog("[Karaoke] seek to \(ms)ms")
    }
}

// MARK: - 播放时钟

final class KaraokePlaybackClock {
    static let shared = KaraokePlaybackClock()

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
        if let seconds = KaraokePositionResolver.shared.currentPositionSeconds() {
            ms = seconds * 1000
        } else {
            ms = currentMs
        }
        currentMs = ms
        onChange?(ms)
    }
}

// MARK: - 叠加视图

private final class LineLabel: UILabel {
    var lineIndex = -1
}

final class LyricsKaraokeOverlayView: UIView {

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var lineLabels: [UILabel] = []
    private var displayTexts: [String] = []
    private var wordRanges: [[Range<String.Index>]] = []
    private var wordIndices: [[Int]] = []

    private var dto: LyricsDto?
    private var dtoVersion = -1
    private var activeLineIndex = -1
    private var activeWordIndex = -1

    private let backgroundColorValue = UIColor(white: 0.04, alpha: 0.97)
    private let lineColor = UIColor(white: 0.72, alpha: 1)
    private let activeLineColorValue = UIColor.white
    private let activeWordColorValue = UIColor.systemYellow

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = .clear

        scrollView.showsVerticalScrollIndicator = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.spacing = 18
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 60),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -60),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48),
        ])
    }

    /// 每帧由时钟调用：惰性取 dto、词级高亮、自动滚动。
    func setCurrentTime(_ ms: Double) {
        if dtoVersion != currentLyricsVersion {
            dto = currentLyricsDto
            dtoVersion = currentLyricsVersion
            rebuild()
        }

        guard let dto, dto.timeSynced else { return }
        let hasWords = dto.lines.contains { $0.words?.isEmpty == false }
        guard hasWords else {
            // 无词级数据：保持透明，不遮挡 Spotify 原生逐行歌词
            if backgroundColor != .clear {
                backgroundColor = .clear
                stackView.isHidden = true
            }
            return
        }

        if backgroundColor != backgroundColorValue {
            backgroundColor = backgroundColorValue
            stackView.isHidden = false
        }

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

        if bestLine == activeLineIndex && bestWord == activeWordIndex { return }

        applyPlain(to: activeLineIndex)
        activeLineIndex = bestLine
        activeWordIndex = bestWord
        if bestLine >= 0 {
            applyHighlight(to: bestLine, wordIndex: bestWord)
            scrollToLine(bestLine)
        }
    }

    private func rebuild() {
        for label in lineLabels { label.removeFromSuperview() }
        lineLabels = []
        displayTexts = []
        wordRanges = []
        wordIndices = []
        activeLineIndex = -1
        activeWordIndex = -1

        guard let dto else { return }

        for (index, line) in dto.lines.enumerated() {
            let (text, ranges, indices) = buildDisplayText(for: line)
            let label = LineLabel()
            label.lineIndex = index
            label.numberOfLines = 0
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 18, weight: .regular)
            label.text = text
            label.textColor = lineColor
            label.isUserInteractionEnabled = true
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleLineTap(_:))))
            stackView.addArrangedSubview(label)
            lineLabels.append(label)
            displayTexts.append(text)
            wordRanges.append(ranges)
            wordIndices.append(indices)
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

    private func applyPlain(to lineIndex: Int) {
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        let label = lineLabels[lineIndex]
        label.attributedText = nil
        label.text = displayTexts[lineIndex]
        label.textColor = lineColor
    }

    private func applyHighlight(to lineIndex: Int, wordIndex: Int) {
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        let label = lineLabels[lineIndex]
        let text = displayTexts[lineIndex]

        let highlighted = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: activeLineColorValue,
            .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
        ])

        let ranges = wordRanges[lineIndex]
        let indices = wordIndices[lineIndex]
        if wordIndex >= 0, let pos = indices.firstIndex(of: wordIndex), pos < ranges.count {
            let range = ranges[pos]
            let nsRange = NSRange(range, in: text)
            highlighted.addAttributes([
                .foregroundColor: activeWordColorValue,
                .font: UIFont.systemFont(ofSize: 18, weight: .bold),
            ], range: nsRange)
        }

        label.attributedText = highlighted
    }

    private func scrollToLine(_ lineIndex: Int) {
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        let label = lineLabels[lineIndex]
        let rect = label.convert(label.bounds, to: scrollView)
        scrollView.scrollRectToVisible(rect, animated: true)
    }

    @objc private func handleLineTap(_ recognizer: UITapGestureRecognizer) {
        guard let label = recognizer.view as? LineLabel,
              let dto = dto, label.lineIndex >= 0, label.lineIndex < dto.lines.count,
              let offset = dto.lines[label.lineIndex].offsetMs else { return }
        KaraokeSeeker.seek(toMs: offset)
    }
}

// MARK: - 挂载管理

final class KaraokeHost {
    static let shared = KaraokeHost()

    private var overlay: LyricsKaraokeOverlayView?
    private weak var hostView: UIView?
    private var isAttached = false

    private var renderEnabled: Bool {
        UserDefaults.standard.bool(forKey: NgzhwmSettingsViewModel.wordByWordLyricsKey)
    }

    func attach(to controller: UIViewController) {
        guard renderEnabled else { return }
        guard !isAttached else { return }
        guard let view = controller.view else { return }

        let overlayView = LyricsKaraokeOverlayView(frame: view.bounds)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlayView)
        view.bringSubviewToFront(overlayView)

        overlay = overlayView
        hostView = view
        isAttached = true

        KaraokePlaybackClock.shared.onChange = { [weak overlayView] ms in
            overlayView?.setCurrentTime(ms)
        }
        KaraokePlaybackClock.shared.start()
        writeDebugLog("[Karaoke] overlay attached")
    }

    func detach() {
        guard isAttached else { return }
        KaraokePlaybackClock.shared.stop()
        KaraokePlaybackClock.shared.onChange = nil
        overlay?.removeFromSuperview()
        overlay = nil
        hostView = nil
        isAttached = false
        writeDebugLog("[Karaoke] overlay detached")
    }
}

// MARK: - 挂载 hook（全屏歌词 VC）

class LyricsKaraokeModernHostHook: ClassHook<UIViewController> {
    typealias Group = ModernLyricsGroup
    static let targetName = "Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        DispatchQueue.main.async {
            KaraokeHost.shared.attach(to: vc)
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        KaraokeHost.shared.detach()
    }
}

class LyricsKaraokeLegacyHostHook: ClassHook<UIViewController> {
    typealias Group = LegacyLyricsGroup
    static let targetName = "Lyrics_CoreImpl.LyricsOnlyViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        DispatchQueue.main.async {
            KaraokeHost.shared.attach(to: vc)
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        KaraokeHost.shared.detach()
    }
}
