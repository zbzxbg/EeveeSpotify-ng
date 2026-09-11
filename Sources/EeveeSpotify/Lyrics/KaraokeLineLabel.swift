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

    /// 漂移校正阈值上限（秒）。FlowX 用固定 0.5s；这里再按段时长收一档，
    /// 避免短行上肉眼可见的错位。
    var driftTolerance: TimeInterval = 0.5

    private let dimLabel = UILabel()
    private let litLabel = UILabel()

    private var rowMasks: [CALayer] = []
    private var maskContainer: CALayer?

    /// 逐词跳动的叠加层：与 litLabel 完全相同的文字，被裁到「当前正在唱的那个词」，
    /// 然后整体做一个垂直位移 —— 遮罩只能表达一维推进，做不了位移，所以需要它。
    private let bounceLabel = UILabel()
    private var bounceMask: CALayer?
    private var bounceSpans: [[WordByWordAxis.WordSpan]] = []
    private var activeBounceWord = -1
    /// 当前正在跳动的词下标（-1 = 无），供 overlay 打日志。
    var activeBounceWordIndex: Int { activeBounceWord }

    private var textString: String?
    private var axis: WordByWordAxis?
    /// 该行在 `LyricsDto.lines` 中的下标（仅用于日志定位）。
    var lineIndex = -1
    /// 未唱部分的透明度。
    ///
    /// 对齐参考实现（SideloadLabs/EeveeSpotifyReincarnated
    /// `KaraokeLineView.swift`）：未唱 `white.opacity(0.35)`，已唱纯白。
    /// 原来取 0.45，对比度不够。
    private var dimOpacity: CGFloat = 0.35
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
    /// 与本行 `cachedVariant` 同源的词时长，供跳动层复用（避免再解析一次）。
    private var cachedTiming: [WordTimingResolver.WordTiming] = []

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

        for label in [dimLabel, litLabel, bounceLabel] {
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

        // 跳动层：同样初始透明，只在建立跳动关键帧时才点亮。
        bounceLabel.layer.opacity = 0
        let mask = CALayer()
        mask.backgroundColor = UIColor.white.cgColor
        bounceMask = mask
        bounceLabel.layer.mask = mask
    }

    /// 逐词跳动幅度（pt）。0 = 关闭。
    ///
    /// 22pt 字号下 1.1pt = 0.05em，对齐参考实现：AMLL `float` 0.05em、
    /// HyperLyrics 0.05/0.06em、am-lyrics 0.033em；Lyricify 出厂
    /// `karaoke_style_float_height` = 2.0。
    /// 旧的 3pt = 0.136em，是全簇的 2.3–4 倍 —— 那是「像抽搐」的来源。
    /// 逐词动效的开关。参考实现没有开关、每个词都做；这里保留一个可以
    /// 一键关掉的杠杆，方便在真机上对比"有动效 / 无动效"。
    var wordMotionEnabled = true

    // MARK: 接口

    /// 设置文本与词在文本中的 NSRange（为空表示该行无词级数据）。
    func setLyric(_ text: String, wordRanges: [NSRange]) {
        guard text != textString || wordRanges != wordNSRanges else { return }
        textString = text
        wordNSRanges = wordRanges
        dimLabel.text = text
        litLabel.text = text
        bounceLabel.text = text
        invalidateAxis()
    }

    func setColors(lit: UIColor, dim: UIColor) {
        litLabel.textColor = lit
        dimLabel.textColor = dim
        bounceLabel.textColor = lit
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
        bounceLabel.font = font
        invalidateAxis()
    }

    /// 文本 / 字体变化会让断行、行宽与全部词边界失效。
    private func invalidateAxis() {
        axisKey = nil
        axis = nil
        wordBoundaries = nil
        bounceSpans = []
        activeBounceWord = -1
        cachedTiming = []
        cachedVariant = nil
        variantFastKey = nil
        variantKey = nil
        anchor = nil
        bounceLabel.layer.removeAnimation(forKey: KaraokeLineLabel.bounceAnimationKey)
        bounceLabel.layer.opacity = 0
        bounceMask?.frame = .zero
        setNeedsLayout()
    }

    /// 行级着色：整行暗（还没到）或整行亮（已唱过）。
    /// 注意这不是「另一套渲染逻辑」——它就是只有两个关键帧的填充特例，
    /// 只不过由调用方直接给出终态。
    ///
    /// 这里**不**改 `litLabel.layer.opacity`：满亮由把每行遮罩铺满实现，
    /// 使淡入淡出（`fade`）可以在其上独立叠加，互不覆盖。
    func setFullyLit(_ lit: Bool) {
        // 只清锚点：轴与关键帧本身仍有效，下次回到本行时能直接复用，
        // 只有「当前动画位置」必须作废（否则会从旧位置继续扫）。
        anchor = nil
        activeBounceWord = -1
        clearBounce()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        litLabel.layer.removeAnimation(forKey: KaraokeLineLabel.fillAnimationKey)
        applyMaskWidths(lit ? fullWidths() : emptyWidths())
        CATransaction.commit()
    }

    /// 每一行铺满时的遮罩宽度（= 行宽本身）。
    /// 硬边遮罩下，宽度等于行宽即整行纯白 —— **行尾必然满亮**。
    private func fullWidths() -> [CGFloat] {
        guard let axis else { return [] }
        return axis.rowWidths
    }

    /// 每一行的隐藏态宽度。
    private func emptyWidths() -> [CGFloat] {
        guard let axis else { return [] }
        return [CGFloat](repeating: 0, count: axis.rowWidths.count)
    }

    /// 把遮罩宽度直接写进模型层（不走动画）。
    /// 硬边遮罩固定贴 `x = 0`，所以只有宽度需要在状态间变化。
    private func applyMaskWidths(_ widths: [CGFloat]) {
        for (row, layer) in rowMasks.enumerated() {
            layer.removeAnimation(forKey: KaraokeLineLabel.fillAnimationKey)
            guard widths.indices.contains(row) else { continue }
            layer.bounds.size.width = widths[row]
        }
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

    /// 填充链路的自检快照 —— 专门用于排查「某些词不亮」这类问题。
    var fillDiagnostics: String {
        guard let axis else { return "no-axis" }
        let rowWidths = axis.rowWidths
        var parts: [String] = []

        // 硬边遮罩：铺满态宽度必须**恰好等于行宽**，此时整行纯白、
        // 没有任何渐变残留。`fullW` 与 `rowW` 不符就是几何算错了。
        parts.append("textW=\(Int(axis.totalWidth)) rows=\(rowWidths.count)")
        for (row, rowWidth) in rowWidths.enumerated() {
            let fullWidth = KaraokeMaskGeometry.maskWidth(sweep: rowWidth, rowWidth: rowWidth)
            parts.append(
                "r\(row):rowW=\(Int(rowWidth)) fullW=\(Int(fullWidth)) "
                    + "hardEdge=true"
            )
        }

        if let variant = cachedVariant, !variant.lineLevel, let boundaries = wordBoundaries,
           !boundaries.isEmpty {
            parts.append("boundaries=\(boundaries.map { Int($0) })")
        }

        return parts.joined(separator: " ")
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

        // 词时长与词矩形是两条路径共用的。
        //
        // ⚠️ 这里曾经算过一个「强调词」集合（时长 ≥1s，非 CJK 再加 2~7 字符，
        // 抄 AMLL 的 `shouldEmphasize`）用来筛掉短词的位移。读完参考实现后
        // 删掉了：它的 `KaraokeWordView` **对每个词都跑三条曲线，没有任何门槛**，
        // 而且位移本身只有 0.75pt —— 真正起作用的是缩放 pop。
        // 用门槛去筛"哪些词配动效"是解决错问题的办法。
        if words.count >= 2 {
            let timing = WordTimingResolver.resolve(words: words, segmentEndMs: segmentEndMs)
            let boundaries = wordBoundaries ?? axis.boundaries(forWordRanges: wordNSRanges)
            wordBoundaries = boundaries
            cachedTiming = timing
            bounceSpans = axis.wordSpans(boundaries: boundaries, words: words)
            activeBounceWord = -1

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
        } else {
            cachedTiming = []
            bounceSpans = []
            activeBounceWord = -1
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
            axis: axis,
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
        let currentTime = stops.anchorPosition + (CACurrentMediaTime() - stops.anchorWallTime)

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

                let widths = stops.stops.map { stop -> CGFloat in
                    KaraokeMaskGeometry.maskWidth(
                        unrolled: stop.sweep,
                        row: row,
                        rowStarts: stops.rowStarts,
                        rowWidths: stops.rowWidths
                    )
                }
                let keyTimes = stops.stops.map { NSNumber(value: $0.keyTime) }
                guard widths.count >= 2, widths.count == keyTimes.count else { continue }

                // 硬边遮罩固定贴 x = 0，因此**只动画宽度**。
                // 参考实现（`KaraokeLineView.swift` 的 `LinearGradient`）也是
                // 只移动那个阶跃的位置 —— 没有羽化，也就没有需要跟着走的柔边。
                let widthAnimation = CAKeyframeAnimation(keyPath: "bounds.size.width")
                widthAnimation.values = widths
                widthAnimation.keyTimes = keyTimes
                widthAnimation.duration = stops.duration
                widthAnimation.calculationMode = .linear
                widthAnimation.isRemovedOnCompletion = false
                widthAnimation.fillMode = .both
                widthAnimation.beginTime = beginTime
                layer.add(widthAnimation, forKey: KaraokeLineLabel.fillAnimationKey)
            }
        }

        anchor = (stops.anchorPosition, stops.anchorWallTime, stops.duration)

        // 逐词动效（缩放 / 上浮 / 辉光）：逐帧写入跳动层。
        applyWordMotion(timing: cachedTiming, currentTime: currentTime)
    }

    // MARK: 跳动层状态

    /// 撤掉跳动层（词间空档 / 无可用几何）。
    private func clearBounce() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounceLabel.layer.removeAnimation(forKey: KaraokeLineLabel.bounceAnimationKey)
        bounceLabel.layer.transform = CATransform3DIdentity
        bounceLabel.layer.shadowOpacity = 0
        bounceLabel.layer.shadowRadius = 0
        bounceLabel.layer.opacity = 0
        bounceMask?.frame = .zero
        CATransaction.commit()
    }

    /// 只在确实还有活动词时才做撤销，避免每帧重复进事务。
    private func clearBounceIfNeeded() {
        guard activeBounceWord != -1 else { return }
        activeBounceWord = -1
        clearBounce()
    }

    private static let bounceAnimationKey = "WordByWordBounce"

    // MARK: 逐词动效曲线（缩放 / 辉光 / 上浮）
    //
    // 数值逐条对齐参考实现 `SideloadLabs/EeveeSpotifyReincarnated`
    // `Karaoke/KaraokeAnimationCurve.swift`（它自己注明是照搬 SpicyLyrics
    // 扩展的 `LyricsAnimator.ts`）：
    //
    //   wordScale = [(0, 0.95), (0.7, 1.0505), (1, 1.0)]
    //   glow      = [(0, 0), (0.15, 1), (0.6, 1), (1, 0)]
    //   yOffset   = [(0, 1/100), (0.9, -(1/60)), (1, 0)]   // × 字号
    //
    // 那边用三次样条，这里用**分段线性**（和它一样：它也刻意用分段线性，
    // 注释说"只有 3-4 个点，样条和线性的视觉差别很细微"）。
    //
    // ⚠️ 竖向上浮的实际幅度**只有约 0.75pt**（28pt 字号下 +0.28 → −0.47）。
    // 真正撑起观感的是 **缩放 pop（0.95 → 1.0505，跨度 10%）** 和
    // **glow 阴影（radius 最大 8pt）**，不是位移。本项目早期只做了位移
    // 而且做到 3pt，方向和权重都错了。

    private enum MotionCurve {
        typealias Point = (time: Double, value: Double)

        static let scale: [Point] = [(0, 0.95), (0.7, 1.0505), (1, 1.0)]
        static let glow: [Point] = [(0, 0), (0.15, 1), (0.6, 1), (1, 0)]
        static let yOffset: [Point] = [(0, 1.0 / 100), (0.9, -(1.0 / 60.0)), (1, 0)]

        /// 分段线性插值，`progress` 应落在 0...1。
        static func value(_ points: [Point], at progress: Double) -> Double {
            let p = min(1, max(0, progress))
            guard points.count > 1 else { return points.first?.value ?? 0 }
            for index in 0..<(points.count - 1) {
                let a = points[index]
                let b = points[index + 1]
                guard p >= a.time && p <= b.time else { continue }
                guard b.time > a.time else { return a.value }
                let local = (p - a.time) / (b.time - a.time)
                return a.value + (b.value - a.value) * local
            }
            return points.last?.value ?? 0
        }
    }

    /// 当前词的运动进度（秒，绝对播放时间）。仅用于日志自检。
    private var lastWordProgress: Double = 0

    /// 每帧把「当前正在唱的词」的缩放 / 上浮 / 辉光写到跳动层上。
    ///
    /// **必须逐帧**：缩放曲线在词内是 0.95 → 1.0505 → 1.0 的连续变化，
    /// `CAKeyframeAnimation` 做得了，但辉光阴影做不到（`shadowRadius` /
    /// `shadowColor` 都不是可靠的可动画属性），而位移只有 0.75pt、
    /// 用关键帧也不划算。参考实现同样是 30Hz 逐帧重算这三条曲线。
    /// 代价只有一次 `transform` + 一次 `shadowOpacity` 写入。
    ///
    /// 门槛：**参考实现没有任何门槛** —— 每个词都跑这三条曲线。
    /// 所以这里也按"当前正在唱的词"处理，不做时长/字数筛选。
    private func applyWordMotion(timing: [WordTimingResolver.WordTiming], currentTime: TimeInterval) {
        guard wordMotionEnabled, cachedVariant != nil else {
            clearBounceIfNeeded()
            return
        }
        guard !bounceSpans.isEmpty, let stops = cachedVariant?.stops else { return }

        let ms = currentTime * 1000
        let active = timing.firstIndex {
            ms >= Double($0.startMs) && ms < Double($0.endMs)
        } ?? -1

        guard active >= 0, timing.indices.contains(active),
              let span = bounceSpans.indices.contains(active)
                  ? bounceSpans[active].first
                  : nil else {
            clearBounceIfNeeded()
            return
        }

        let word = timing[active]
        let progress = stops.wordProgress(
            startMs: word.startMs,
            endMs: word.endMs,
            atTime: currentTime
        )
        lastWordProgress = progress
        activeBounceWord = active

        let scale = MotionCurve.value(MotionCurve.scale, at: progress)
        let glow = MotionCurve.value(MotionCurve.glow, at: progress)
        let yFraction = MotionCurve.value(MotionCurve.yOffset, at: progress)
        let pointOffset = CGFloat(yFraction) * motionFontSize

        updateBounceMask(span: span)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounceLabel.layer.opacity = 1
        // 先平移到词中心 → 以该点缩放 → 再平移回去，等价于"围绕词中心缩放"。
        // 直接改 anchorPoint 会连带移动 position，换算容易出错，这样更稳。
        let height = lineHeight()
        let centerX = span.x + span.width / 2
        let centerY = CGFloat(span.row) * height + height / 2
        let s = CGFloat(scale)
        let toCenter = CATransform3DMakeTranslation(-centerX, -centerY, 0)
        let scaleUp = CATransform3DMakeScale(s, s, 1)
        let back = CATransform3DMakeTranslation(centerX, centerY + pointOffset, 0)
        bounceLabel.layer.transform = CATransform3DConcat(toCenter, CATransform3DConcat(scaleUp, back))
        bounceLabel.layer.shadowColor = UIColor.white.cgColor
        bounceLabel.layer.shadowOpacity = Float(glow * 0.8)
        bounceLabel.layer.shadowRadius = CGFloat(glow * 8)
        bounceLabel.layer.shadowOffset = .zero
        CATransaction.commit()
    }

    /// 逐词动效里"字号"的基准（参考实现用 28pt，本项目歌词字号 22pt）。
    private var motionFontSize: CGFloat { dimLabel.font?.pointSize ?? 22 }

    private func lineHeight() -> CGFloat { max(1, dimLabel.font?.lineHeight ?? 20) }

    /// 把跳动层裁到当前词的矩形上（跨行的词取第一段）。
    ///
    /// 遮罩保持**静止**，缩放只作用于被裁出来的内容 —— 与参考实现的
    /// `scaleEffect` 包住整词一致。
    private func updateBounceMask(span: WordByWordAxis.WordSpan) {
        let height = lineHeight()
        let padding: CGFloat = 1
        bounceMask?.frame = CGRect(
            x: max(0, span.x - padding),
            y: CGFloat(span.row) * height,
            width: span.width + padding * 2,
            height: height
        )
    }

    // MARK: 行级视觉（缩放 / 模糊）
    //
    // AMLL 在**逐词模式下不靠透明度区分非活动行** —— `resolveOpacity` 给
    // 高亮行 0.85、其余行 1，区分全靠缩放（`SCALE_ASPECT = 97`）与模糊
    // （`level = 1 + distance`，上限 5px）。缺了这两样，用户就读不出"当前唱到哪一行"。
    //
    // ⚠️ LyricFever 源码里记了一个坑：用**新行**做动画基准会让上一行看起来
    // 先动（*"appear to 'push' Lyric 1 upward"*）。这里只做静态的
    // 目标值 + 短过渡，不做逐行错峰，避免同类问题。

    /// 非活动行的缩放。AMLL 用 0.97。
    private let inactiveScale: CGFloat = 0.97

    /// 按「距当前行几行」设置缩放与模糊。distance == 0 即当前行。
    ///
    /// 模糊用 `CIGaussianBlur` 在逐行动画下太贵，这里用
    /// 「缩放 + 基础透明度」表达层次；模糊梯度留待后续按需接入。
    func setLineEmphasis(distance: Int, animated: Bool = true) {
        let clamped = max(0, distance)
        let targetScale: CGFloat = clamped == 0 ? 1.0 : inactiveScale
        // 越远越暗，但**当前行的未唱部分仍然比邻行亮**，这是 AMLL 的 pop。
        let targetAlpha: CGFloat = clamped == 0 ? 1.0 : max(0.55, 1.0 - CGFloat(clamped) * 0.12)

        guard abs(currentEmphasisScale - targetScale) > 0.001
            || abs(currentEmphasisAlpha - targetAlpha) > 0.001 else { return }

        currentEmphasisScale = targetScale
        currentEmphasisAlpha = targetAlpha

        let apply = { [weak self] in
            guard let self else { return }
            self.transform = CGAffineTransform(scaleX: targetScale, y: targetScale)
            self.alpha = targetAlpha
        }

        guard animated else {
            apply()
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: apply)
    }

    private var currentEmphasisScale: CGFloat = 1
    private var currentEmphasisAlpha: CGFloat = 1

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
        cachedTiming = []
        bounceSpans = []
        activeBounceWord = -1
        bounceLabel.layer.removeAnimation(forKey: KaraokeLineLabel.bounceAnimationKey)
        bounceLabel.layer.opacity = 0
        bounceMask?.frame = .zero

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

    /// 每行一条**纯色**遮罩子层，固定贴 `x = 0`，宽度即"已唱到哪"。
    ///
    /// ⚠️ 这里曾经用 `CAGradientLayer` 做空间羽化，那是错的。参考实现
    /// （`SideloadLabs/EeveeSpotifyReincarnated` `Karaoke/KaraokeLineView.swift`）
    /// 的填充是一个 `LinearGradient`，中间两个 stop **共用同一个 location**，
    /// 即**阶跃、零羽化**；Volta 用 `Rectangle().frame(width:)`、juejin 那篇
    /// Flutter 作者也是硬边。空间羽化会让每个词唱完后词尾立刻变暗，
    /// 一行多个词就是多次「亮→暗→亮」，读起来像锯齿。
    ///
    /// 平滑由**时间轴**负责（这边是关键帧间的线性插值，参考实现是
    /// `progress` 上挂 80ms 线性动画），不需要空间上的柔边。
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
            let layer = CALayer()
            layer.backgroundColor = UIColor.white.cgColor
            layer.anchorPoint = CGPoint(x: 0, y: 0.5)
            // 贴 x = 0，初始宽度 0（未唱）。宽度由关键帧驱动。
            layer.position = CGPoint(x: 0, y: CGFloat(row) * lineHeight + lineHeight / 2)
            layer.bounds = CGRect(x: 0, y: 0, width: 0, height: lineHeight)

            container.addSublayer(layer)
            rowMasks.append(layer)
        }

        // 行数一致性：轴的行数、行宽数量、行偏移数量必须对齐，
        // 否则遮罩子层会与关键帧的 widths 数量错位。
        assert(rowCount == rowWidths.count, "axis row count mismatch")

        litLabel.layer.mask = container
        maskContainer = container
    }

    /// 逐词动效状态自检。
    var bounceDiagnostics: String {
        guard wordMotionEnabled else { return "motion=off" }
        let descriptions = bounceSpans.map { group -> String in
            group.first.map { "r\($0.row)x=\(Int($0.x))w=\(Int($0.width))" } ?? "empty"
        }
        return "motion=on word=\(activeBounceWord) "
            + "progress=\(String(format: "%.2f", lastWordProgress)) "
            + "spans=[\(descriptions.joined(separator: ","))]"
    }

    private static let fillAnimationKey = "WordByWordFill"

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
