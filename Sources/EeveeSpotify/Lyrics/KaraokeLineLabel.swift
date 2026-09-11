import Foundation
import CoreGraphics
import QuartzCore
import UIKit

// MARK: - 逐词填充歌词行
//
// 双层文字 + 逐行遮罩：
//
//   dimLabel —— 未唱的暗字（整行铺满，恒定透明度）
//   litLabel —— 唱到的亮字，其 layer.mask 是一组水平渐变子层，
//               每行一条，宽度由 CAKeyframeAnimation 驱动
//
// 为什么是「关键帧动画」而不是「每帧改宽度」：
//   CADisplayLink 每帧写 mask 宽度是纯主线程开销，而这个 tweak 跑在 Spotify
//   进程里、和音频解码抢同一个主线程。CAKeyframeAnimation 建好之后由 Core
//   Animation 合成器插值，主线程零开销（FlowX 的 "zero-CPU" 就是这个意思）。
//   CADisplayLink 因此降级为**看门狗**：只在 seek / 卡顿时重建动画。
//
// 为什么只有词边界是关键帧、词内不做关键帧：
//   词内推进交给线性插值 —— 这就是那条连续「唱针」，而不是逐词跳变。
//   这是与旧实现（逐词改 NSAttributedString 颜色）的本质区别：
//   旧实现两次词边界之间屏幕是静止的。
//
// ⚠️ 长度单位全部是**秒**（与 CAAnimation 一致）。本模块唯一的毫秒来源是
//    `LyricsDto` / `LyricsWordDto`，换算只发生在调用方传入处。
//
// 非 final：overlay 通过 `LineLabel` 子类持有它（见 LyricsWordByWord.x.swift）。

class KaraokeLineLabel: UIView {

    /// 行内羽化边宽度（pt）。参考 KaraokeText 的 `feather` 默认
    /// `min(width × 0.6, 34)`；这里取固定 16pt，因为歌词字号固定，
    /// 固定柔边比按宽度缩放更稳定。
    var feather: CGFloat = 16

    /// 漂移校正阈值上限（秒）。FlowX 用固定 0.5s；这里再按段时长收一档，
    /// 避免短行上肉眼可见的错位。
    var driftTolerance: TimeInterval = 0.5

    private let dimLabel = UILabel()
    private let litLabel = UILabel()

    private var rowMasks: [CAGradientLayer] = []
    private var maskContainer: CALayer?

    private var textString: String?
    private var axis: WordByWordAxis?
    /// 该行在 `LyricsDto.lines` 中的下标（仅用于日志定位）。
    var lineIndex = -1
    /// 未唱部分的透明度。默认与旧实现的 `unsungWordOpacity` 一致，
    /// 保证观感不因这次改动而突变；由 overlay 通过 `setDimOpacity` 覆写。
    private var dimOpacity: CGFloat = 0.45
    private var axisKey: String?
    private var wordNSRanges: [NSRange] = []
    private var wordBoundaries: [CGFloat]?

    /// 当前填充段的锚点；为 nil 表示尚未建立动画。
    private var anchor: (position: TimeInterval, wall: CFTimeInterval, duration: TimeInterval)?

    /// 关键帧缓存。`setFill` 每帧都会被调用（看门狗需要每帧比较漂移），
    /// 但关键帧只在「换行 / 布局变化 / 数据变化」时才会变，因此这里做两层缓存：
    ///   - `variantFastKey`：O(1) 判等，命中即整帧零分配直接返回；
    ///   - `variantKey`：含词时间的完整键，用于数据被替换（换歌、罗马化重算）时失效。
    private var cachedVariant: WordByWordFillVariant?
    private var variantFastKey: String?
    private var variantKey: String?

    private static let fillAnimationKey = "WordByWordFill"

    // MARK: 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = false

        for label in [dimLabel, litLabel] {
            label.numberOfLines = 0
            label.textAlignment = .left
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor),
                label.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        // 亮层初始全暗：由填充决定露出多少。
        litLabel.layer.opacity = 0
        dimLabel.layer.opacity = Float(dimOpacity)
    }

    // MARK: 接口

    /// 设置文本与词在文本中的 NSRange（为空表示该行无词级数据）。
    func setLyric(_ text: String, wordRanges: [NSRange]) {
        guard text != textString || wordRanges != wordNSRanges else { return }
        textString = text
        wordNSRanges = wordRanges
        dimLabel.text = text
        litLabel.text = text
        invalidateAxis()
    }

    func setColors(lit: UIColor, dim: UIColor) {
        litLabel.textColor = lit
        dimLabel.textColor = dim
    }

    /// 未唱部分的透明度。由 overlay 传入，保证「观感参数」集中在一处可调。
    func setDimOpacity(_ opacity: CGFloat) {
        guard dimOpacity != opacity else { return }
        dimOpacity = opacity
        dimLabel.layer.opacity = Float(opacity)
    }

    func setFont(_ font: UIFont) {
        guard dimLabel.font != font else { return }
        dimLabel.font = font
        litLabel.font = font
        invalidateAxis()
    }

    /// 文本 / 字体变化会让断行、行宽与全部词边界失效。
    private func invalidateAxis() {
        axisKey = nil
        axis = nil
        wordBoundaries = nil
        cachedVariant = nil
        variantFastKey = nil
        variantKey = nil
        anchor = nil
        setNeedsLayout()
    }

    /// 行级着色：整行暗（还没到）或整行亮（已唱过）。
    /// 注意这不是「另一套渲染逻辑」——它就是只有两个关键帧的填充特例，
    /// 只不过由调用方直接给出终态。
    ///
    /// 这里**不**改 `litLabel.layer.opacity`：满亮由把每行遮罩填到满宽实现，
    /// 使淡入淡出（`fade`）可以在其上独立叠加，互不覆盖。
    func setFullyLit(_ lit: Bool) {
        // 只清锚点：轴与关键帧本身仍有效，下次回到本行时能直接复用，
        // 只有「当前动画位置」必须作废（否则会从旧位置继续扫）。
        anchor = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        litLabel.layer.removeAnimation(forKey: KaraokeLineLabel.fillAnimationKey)
        for (row, layer) in rowMasks.enumerated() {
            layer.removeAnimation(forKey: KaraokeLineLabel.fillAnimationKey)
            layer.bounds.size.width = lit ? fullWidth(row) : 0
        }
        CATransaction.commit()
    }

    /// 把填充推进到指定时刻（秒，绝对播放时间）。
    ///
    /// - Parameters:
    ///   - words: 本行词级数据；为空表示没有词级时间轴（走行级填充基例）。
    ///   - segmentStartMs / segmentEndMs: 本行的时间窗（毫秒）。
    ///     词级填充只用它们做兜底；实际锚点取第一个词的起始时间。
    ///   - currentTime: 当前播放进度（秒）。
    func setFill(
        words: [LyricsWordDto],
        segmentStartMs: Int,
        segmentEndMs: Int,
        currentTime: TimeInterval
    ) {
        guard let axis, !axis.isEmpty else { return }
        guard segmentEndMs > segmentStartMs else { return }

        // 快路径：几何与时间窗都没变 → 关键帧必然相同，整帧不做任何分配。
        let fastKey = "\(axisKey ?? "")|\(segmentStartMs)|\(segmentEndMs)|\(words.count)"
        if fastKey == variantFastKey, cachedVariant != nil {
            let tolerance = max(0.08, min(driftTolerance, (cachedVariant?.duration ?? 1) * 0.5))
            if let anchor {
                let expected = anchor.position + (CACurrentMediaTime() - anchor.wall)
                if abs(currentTime - expected) <= tolerance {
                    return
                }
            }
        }

        // 慢路径：词时间可能被替换（换歌、罗马化重算），用含时间的完整键判等。
        let fullKey = "\(fastKey)|\(words.first?.startMs ?? -1)|\(words.last?.endMs ?? -1)"
            + "|\(words.last?.startMs ?? -1)"
        let variant: WordByWordFillVariant?
        if fullKey == variantKey, let cachedVariant {
            variant = cachedVariant
        } else {
            variant = buildVariant(
                axis: axis,
                words: words,
                segmentStartMs: segmentStartMs,
                segmentEndMs: segmentEndMs
            )
            variantKey = fullKey
        }
        guard let variant else { return }

        variantFastKey = fastKey
        cachedVariant = variant

        let tolerance = max(0.08, min(driftTolerance, variant.duration * 0.5))
        var resync = false

        if let anchor {
            let expected = anchor.position + (CACurrentMediaTime() - anchor.wall)
            resync = abs(currentTime - expected) > tolerance || anchor.duration != variant.duration
        } else {
            resync = true
        }

        apply(variant: variant, rebuild: resync)
    }

    /// 几何是否已就绪（轴已建立且遮罩子层存在）。
    /// 未就绪时 `setFill` 会静默跳过 —— 布局完成后的首帧会自动补上。
    var hasUsableGeometry: Bool { axis?.isEmpty == false && !rowMasks.isEmpty }

    /// 轴向自检摘要（行数 / 每行宽度 / 累积宽度 / 词边界数 / 单调性）。
    /// 轴算错时不会崩溃也不会报错，只会「看起来偏了一点」，
    /// 因此必须能打出来和设备上的实际渲染对照。
    var axisDiagnostics: String { axis?.diagnostics.summary ?? "no-axis" }

    /// 最近一次实际建立的填充：是否离散基例 + 关键帧数。
    var lastVariantSummary: String {
        guard let variant = cachedVariant else { return "none" }
        return variant.lineLevel
            ? "discrete(stops=\(variant.stopCount))"
            : "wordLevel(stops=\(variant.stopCount), \(String(format: "%.2fs", variant.duration)))"
    }

    // MARK: 填充数据

    private func buildVariant(
        axis: WordByWordAxis,
        words: [LyricsWordDto],
        segmentStartMs: Int,
        segmentEndMs: Int
    ) -> WordByWordFillVariant? {
        guard segmentEndMs > segmentStartMs else { return nil }

        // 时间锚点用**第一个词的起始时间**而非行 offsetMs：两者之间常有前奏空档，
        // 用词时间才能保证空档期间唱针停在最左端。
        let firstWordMs = words.first?.startMs ?? segmentStartMs
        let lastWordEndMs = words.last?.endMs ?? words.last?.startMs ?? segmentEndMs

        // 收尾留一点 post-roll，让最后一个音节之后唱针自然补完；
        // 但不越过下一行的起点，避免与下一行的填充重叠。
        let fillEndMs = min(max(lastWordEndMs + 400, firstWordMs + 300), segmentEndMs)
        let duration = Double(fillEndMs - firstWordMs) / 1000
        let anchorPosition = Double(firstWordMs) / 1000

        if words.count >= 2 {
            let timing = WordTimingResolver.resolve(words: words, segmentEndMs: segmentEndMs)
            let boundaries = wordBoundaries ?? axis.boundaries(forWordRanges: wordNSRanges)
            wordBoundaries = boundaries

            if WordTimingResolver.isUsableForFill(timing), boundaries.count == timing.count + 1,
               let stops = WordByWordKeyframes.wordLevel(
                   axis: axis,
                   timing: timing,
                   boundaries: boundaries,
                   rowWidths: axis.rowWidths,
                   segmentStartMs: firstWordMs,
                   segmentEndMs: fillEndMs,
                   anchorPosition: anchorPosition
               ) {
                return WordByWordFillVariant(stops: stops, lineLevel: false)
            }
        }

        // 离散基例：无词级数据 / 只有单个词 / 词级数据退化。
        // 整行在「第一个词开始唱」或「行起始」时一次性点亮。
        // 只有在本行确实带了词级数据却仍然降级时才记日志 —— 那才是异常情况，
        // 无词级数据的行（占多数）不该刷屏。
        if words.count >= 2 {
            writeDebugLog(
                "[WordByWord] line \(lineIndex) word timing degraded "
                    + "(\(words.count) words) — discrete fill"
            )
        }
        let stops = WordByWordKeyframes.discrete(
            rowWidths: axis.rowWidths,
            keyTime: 0.02,
            duration: max(0.3, duration),
            anchorPosition: anchorPosition
        )
        return WordByWordFillVariant(stops: stops, lineLevel: true)
    }

    // MARK: 应用

    /// 把关键帧装到每一行的遮罩子层。
    /// 动画位置由 `stops.anchorWallTime` 推出的 `beginTime` 决定，
    /// 因此不需要再单独传入当前播放时刻。
    private func apply(variant: WordByWordFillVariant, rebuild: Bool) {
        guard !rowMasks.isEmpty else { return }
        let stops = variant.stops

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        litLabel.layer.opacity = 1

        if rebuild {
            let now = CACurrentMediaTime()
            let elapsed = now - stops.anchorWallTime
            let beginTime = now - elapsed

            for (row, layer) in rowMasks.enumerated() {
                layer.removeAnimation(forKey: KaraokeLineLabel.fillAnimationKey)

                let values = stops.stops.map { stop -> CGFloat in
                    stop.widths.indices.contains(row) ? stop.widths[row] : 0
                }
                let keyTimes = stops.stops.map { NSNumber(value: $0.keyTime) }
                guard values.count >= 2, values.count == keyTimes.count else { continue }

                let animation = CAKeyframeAnimation(keyPath: "bounds.size.width")
                animation.values = values
                animation.keyTimes = keyTimes
                animation.duration = stops.duration
                animation.calculationMode = .linear
                animation.isRemovedOnCompletion = false
                animation.fillMode = .both
                animation.beginTime = beginTime
                layer.add(animation, forKey: KaraokeLineLabel.fillAnimationKey)
            }
        }

        anchor = (stops.anchorPosition, stops.anchorWallTime, stops.duration)
    }

    // MARK: 遮罩几何

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildMaskIfNeeded()
    }

    /// label 宽度变化会让断行、每行宽度、以及所有词边界全部失效，
    /// 因此以「文本 + 宽度」为键缓存轴，键不变则不重算。
    private func rebuildMaskIfNeeded() {
        guard let text = textString, !text.isEmpty else {
            clearRowMasks()
            axis = nil
            axisKey = nil
            return
        }

        let width = bounds.width
        guard width > 1 else { return }

        let key = "\(Int(width.rounded()))|\(text.count)|\(text.hashValue)"
        guard key != axisKey else { return }

        axisKey = key
        wordBoundaries = nil
        anchor = nil
        cachedVariant = nil
        variantFastKey = nil
        variantKey = nil

        let newAxis = WordByWordAxis(
            displayText: text,
            font: dimLabel.font,
            containerWidth: width
        )
        axis = newAxis
        rebuildRowMasks()
        writeDebugLog("[WordByWord] axis rebuilt w=\(Int(width)) rows=\(newAxis?.rows ?? 0)")
    }

    private func clearRowMasks() {
        guard !rowMasks.isEmpty || maskContainer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in rowMasks { layer.removeFromSuperlayer() }
        rowMasks = []
        litLabel.layer.mask = nil
        maskContainer = nil
        CATransaction.commit()
    }

    /// 每行一条水平渐变子层，作为亮层的遮罩。
    /// 用 CAGradientLayer 而非纯色 CALayer，是为了拿到**羽化边**
    /// —— 纯色遮罩是硬边，视觉上会明显廉价（KaraokeText 的 feathered sweep）。
    private func rebuildRowMasks() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for layer in rowMasks { layer.removeFromSuperlayer() }
        rowMasks = []

        guard let axis, !axis.isEmpty else {
            litLabel.layer.mask = nil
            maskContainer = nil
            return
        }

        let rowWidths = axis.rowWidths
        let lineHeight = max(1, dimLabel.font?.lineHeight ?? 20)
        let rowCount = axis.rowOffsets.starts.count
        let container = CALayer()

        for row in rowWidths.indices {
            let layer = CAGradientLayer()
            layer.anchorPoint = CGPoint(x: 0, y: 0.5)
            layer.position = CGPoint(x: 0, y: CGFloat(row) * lineHeight + lineHeight / 2)
            layer.bounds = CGRect(x: 0, y: 0, width: 0, height: lineHeight)

            layer.startPoint = CGPoint(x: 0, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 0.5)

            let width = max(1, rowWidths[row])
            let fade = min(0.45, max(0.02, feather / width))
            layer.locations = [0, NSNumber(value: 1 - Double(fade)), 1]
            layer.colors = [
                UIColor.white.cgColor,
                UIColor.white.cgColor,
                UIColor.white.withAlphaComponent(0).cgColor,
            ]

            container.addSublayer(layer)
            rowMasks.append(layer)
        }

        // 行数一致性：轴的行数、行宽数量、行偏移数量必须对齐，
        // 否则遮罩子层会与关键帧的 widths 数量错位。
        assert(rowCount == rowWidths.count, "axis row count mismatch")

        litLabel.layer.mask = container
        maskContainer = container
    }

    private func fullWidth(_ row: Int) -> CGFloat {
        guard let axis, row < axis.rowWidths.count else { return 0 }
        return axis.rowWidths[row]
    }

    // MARK: 动画过渡

    /// 行切换时的淡入淡出（进入当前行淡入、离开淡出）。
    /// 用 layer.opacity 的显式动画而不是 UIView.transition：后者会对整个
    /// 视图做快照，而本视图带 mask 子层，快照会丢掉遮罩状态。
    ///
    /// 这里**不设守卫**：模型值保持 1，靠 fromValue/toValue 表达过渡，
    /// 因此「正在淡入时又收到淡入」只是叠加一条新动画，不会产生跳变。
    func fade(toLit lit: Bool, duration: TimeInterval = 0.15) {
        let from = litLabel.layer.presentation()?.opacity ?? litLabel.layer.opacity
        let to: Float = lit ? 1 : 0
        guard abs(from - to) > 0.01 else { return }

        litLabel.layer.opacity = 1

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        litLabel.layer.add(animation, forKey: KaraokeLineLabel.fadeAnimationKey)
    }

    private static let fadeAnimationKey = "WordByWordFade"
}

// MARK: - 内部数据结构

/// 一次填充的完整描述。
struct WordByWordFillVariant {
    var stops: WordByWordFillStops
    /// 是否走了离散基例（无词级数据 / 只有单个词 / 词级数据退化）。
    /// 供 overlay 打诊断日志用。
    var lineLevel: Bool
    var duration: TimeInterval { stops.duration }
    var stopCount: Int { stops.stops.count }
}
