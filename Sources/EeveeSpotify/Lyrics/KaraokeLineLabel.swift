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

    /// 羽化长度（pt）。**只与字号挂钩，绝不与行宽或遮罩宽度挂钩** ——
    /// 与行宽挂钩会让长行糊、短行硬边；与遮罩宽度挂钩（旧实现）会让羽化
    /// 在动画过程中从几 px 漂到上百 px，这正是「比上一版更糊」的原因。
    ///
    /// 由 `setFont` 按 `KaraokeMaskGeometry.featherRatio` 自动赋值。
    private(set) var feather: CGFloat = 13

    /// 漂移校正阈值上限（秒）。FlowX 用固定 0.5s；这里再按段时长收一档，
    /// 避免短行上肉眼可见的错位。
    var driftTolerance: TimeInterval = 0.5

    private let dimLabel = UILabel()
    private let litLabel = UILabel()

    private var rowMasks: [CAGradientLayer] = []
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
    var bounceHeight: CGFloat = 1.1

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
        feather = KaraokeMaskGeometry.featherWidth(fontSize: font.pointSize)
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
        litLabel.layer.removeAnimation(forKey: KaraokeLineLabel.positionAnimationKey)
        applyFrames(frames: lit ? fullFrames() : emptyFrames())
        CATransaction.commit()
    }

    /// 每一行铺满时的遮罩 frame。
    ///
    /// 铺满时 `x = -feather`，不透明区正好是 `[0, rowWidth]` ——
    /// **行尾必然满亮**，不需要额外的 trail 余量。
    private func fullFrames() -> [WordByWordMaskFrame] {
        guard let axis else { return [] }
        return axis.frames(atUnrolled: axis.totalWidth, feather: feather)
    }

    /// 每一行的隐藏态 frame（整块停在行左缘之外）。
    private func emptyFrames() -> [WordByWordMaskFrame] {
        guard let axis else { return [] }
        let rowStarts = axis.rowOffsets.starts
        return axis.rowWidths.indices.map { row in
            KaraokeMaskGeometry.frame(
                unrolled: max(0, rowStarts[row]),
                row: row,
                rowStarts: rowStarts,
                rowWidths: axis.rowWidths,
                feather: feather
            )
        }
    }

    /// 把 frame 直接写进模型层（不走动画）。
    /// 宽度在所有状态间都相同（行宽 + 羽化），只有 `x` 在变。
    private func applyFrames(frames: [WordByWordMaskFrame]) {
        for (row, layer) in rowMasks.enumerated() {
            layer.removeAnimation(forKey: KaraokeLineLabel.fillAnimationKey)
            layer.removeAnimation(forKey: KaraokeLineLabel.positionAnimationKey)
            guard frames.indices.contains(row) else { continue }
            let frame = frames[row]
            layer.bounds.size.width = frame.width
            layer.position.x = frame.x
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
    ///
    /// 逐词的**实际落点**都在这里：每个词在展平轴上的起止、对应的遮罩
    /// frame、以及该 frame 在行内的覆盖范围是否真的越过了行尾。
    /// `tailCovered=false` 就是「行尾不亮」的直接证据。
    var fillDiagnostics: String {
        guard let axis else { return "no-axis" }
        let rowWidths = axis.rowWidths
        var parts: [String] = []

        parts.append("textW=\(Int(axis.totalWidth)) rows=\(rowWidths.count) feather=\(Int(feather))")

        // 铺满态自检：不透明区起点 = x，终点 = x + rowWidth。
        // 要「整行点亮」必须 x <= 0 且 x + rowWidth >= rowWidth，
        // 也就是 x ∈ [-feather, 0] —— 新几何下恒为 x = -feather。
        let full = fullFrames()
        for (row, frame) in full.enumerated() {
            let opaqueEnd = frame.x + rowWidths[row]
            let covered = frame.x <= 0.01 && opaqueEnd >= rowWidths[row] - 0.5
            parts.append(
                "r\(row):w=\(Int(rowWidths[row])) full[x=\(Int(frame.x)) "
                    + "mask=\(Int(frame.width)) opaqueEnd=\(Int(opaqueEnd)) tailCovered=\(covered)]"
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

        // 词时长与词矩形是两条路径共用的（离散基例也需要它们来判定强调词）。
        var emphasized: Set<Int> = []
        if words.count >= 2 {
            let timing = WordTimingResolver.resolve(words: words, segmentEndMs: segmentEndMs)
            let boundaries = wordBoundaries ?? axis.boundaries(forWordRanges: wordNSRanges)
            wordBoundaries = boundaries
            cachedTiming = timing
            bounceSpans = axis.wordSpans(boundaries: boundaries, words: words)
            activeBounceWord = -1
            for index in timing.indices where WordTimingResolver.shouldEmphasize(timing[index]) {
                emphasized.insert(index)
            }

            if WordTimingResolver.isUsableForFill(timing), boundaries.count == timing.count + 1,
               let stops = WordByWordKeyframes.wordLevel(
                   axis: axis,
                   timing: timing,
                   boundaries: boundaries,
                   rowWidths: axis.rowWidths,
                   feather: feather,
                   segmentStartMs: firstWordMs,
                   segmentEndMs: fillEndMs,
                   anchorPosition: anchorPosition
               ) {
                return WordByWordFillVariant(
                    stops: stops,
                    lineLevel: false,
                    emphasizedWords: emphasized
                )
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
            feather: feather,
            keyTime: 0.02,
            duration: max(0.3, duration),
            anchorPosition: anchorPosition
        )
        return WordByWordFillVariant(stops: stops, lineLevel: true, emphasizedWords: emphasized)
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
                layer.removeAnimation(forKey: KaraokeLineLabel.positionAnimationKey)

                let frames = stops.stops.map { stop -> WordByWordMaskFrame in
                    stop.frames.indices.contains(row)
                        ? stop.frames[row]
                        : WordByWordMaskFrame(x: 0, width: 0)
                }
                let keyTimes = stops.stops.map { NSNumber(value: $0.keyTime) }
                guard frames.count >= 2, frames.count == keyTimes.count else { continue }

                // **只动画 position.x，不动宽度。**
                // 宽度固定是「羽化恒定」的前提：一旦宽度是动画量，
                // 按宽度百分比定义的 locations 就会让羽化在几 px 到上百 px
                // 之间漂移 —— 那正是上一版「糊」的成因。
                // 机制同 AMLL animator-web.ts / SPlayer DefaultLyric.vue。
                let positionAnimation = CAKeyframeAnimation(keyPath: "position.x")
                positionAnimation.values = frames.map(\.x)
                positionAnimation.keyTimes = keyTimes
                positionAnimation.duration = stops.duration
                positionAnimation.calculationMode = .linear
                positionAnimation.isRemovedOnCompletion = false
                positionAnimation.fillMode = .both
                positionAnimation.beginTime = beginTime
                layer.add(positionAnimation, forKey: KaraokeLineLabel.positionAnimationKey)
            }
        }

        anchor = (stops.anchorPosition, stops.anchorWallTime, stops.duration)

        // 跳动层：只在活动词变化时才真正重建，常规帧在这里直接返回。
        updateBounce(
            timing: cachedTiming,
            emphasized: variant.emphasizedWords,
            currentTime: currentTime
        )
    }

    // MARK: 逐词跳动

    /// 找到当前正在唱的**强调词**并重建跳动动画。
    ///
    /// 只在**目标词发生变化**时才重建：关键帧数组与词数同阶，
    /// 每帧重建会白白分配一堆数组（本模块的整个设计就是避免这件事）。
    ///
    /// - Parameter emphasized: 够长、值得上位移的词下标集合。
    ///   空集合表示整行都不做位移，此时只撤掉跳动层。
    private func updateBounce(
        timing: [WordTimingResolver.WordTiming],
        emphasized: Set<Int>,
        currentTime: TimeInterval
    ) {
        guard let axis, !bounceSpans.isEmpty, bounceHeight > 0 else { return }
        guard !emphasized.isEmpty else {
            clearBounceIfNeeded()
            return
        }
        let ms = currentTime * 1000

        // 当前正在唱的词，且必须在强调集合里 —— 否则保持静止。
        let active = timing.firstIndex {
            ms >= Double($0.startMs) && ms < Double($0.endMs)
        } ?? -1
        let target = (active >= 0 && emphasized.contains(active)) ? active : -1

        guard target != activeBounceWord else { return }
        activeBounceWord = target

        guard target >= 0, timing.indices.contains(target) else {
            // 词间空档 / 短词：撤掉跳动层，唱针停在原处。
            clearBounce()
            return
        }

        // 遮罩移动要走事务禁用隐式动画；跳动动画本身是显式的，
        // 必须在事务之外挂上去，否则会被这里的 setDisableActions 影响。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateBounceMask(wordIndex: target, axis: axis, currentTime: currentTime, timing: timing)
        CATransaction.commit()

        writeDebugLog(
            "[WordByWord/Bounce] word=\(target) \"\(timing[target].text)\" "
                + "span=\(bounceSpanDescription(target)) "
                + "start=\(timing[target].startMs)ms end=\(timing[target].endMs)ms"
        )

        addBounceAnimation(wordIndex: target, timing: timing, axis: axis)
    }

    private func bounceSpanDescription(_ wordIndex: Int) -> String {
        guard bounceSpans.indices.contains(wordIndex) else { return "none" }
        let spans = bounceSpans[wordIndex]
        guard !spans.isEmpty else { return "empty" }
        return spans.map { "r\($0.row)x=\(Int($0.x))w=\(Int($0.width))" }.joined(separator: "+")
    }

    /// 撤掉跳动层（词间空档 / 短词 / 整行无强调词）。
    private func clearBounce() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounceLabel.layer.removeAnimation(forKey: KaraokeLineLabel.bounceAnimationKey)
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

    /// 把跳动层裁到「当前词已经唱到的那一段」。
    ///
    /// 宽度跟着填充推进，而不是整词一次露出：否则短词会出现
    /// 「字还没唱到就已经整词发亮」。
    private func updateBounceMask(
        wordIndex: Int,
        axis: WordByWordAxis,
        currentTime: TimeInterval,
        timing: [WordTimingResolver.WordTiming]
    ) {
        guard bounceSpans.indices.contains(wordIndex),
              let span = bounceSpans[wordIndex].first,
              timing.indices.contains(wordIndex) else { return }

        let lineHeight = max(1, dimLabel.font?.lineHeight ?? 20)
        let padding: CGFloat = 1

        let word = timing[wordIndex]
        let start = Double(word.startMs) / 1000
        let end = Double(word.endMs) / 1000
        let progress = end > start
            ? min(1, max(0, (currentTime - start) / (end - start)))
            : 1

        bounceLabel.layer.opacity = 1
        bounceMask?.frame = CGRect(
            x: max(0, span.x - padding),
            y: CGFloat(span.row) * lineHeight,
            width: max(0, span.width * CGFloat(progress) + padding * 2),
            height: lineHeight
        )
    }

    /// 单个词的「抬起 → 保持 → 回落」。
    ///
    /// 形制取自 AMLL `animation/float/index.ts`：`translateY(0 → -0.05em)`、
    /// `ease-out`、**抬起后保持**，而不是快起快落再弹一下。
    ///
    /// ⚠️ 旧实现用的是带回弹过冲的 `cubic-bezier(0.34, 1.56, …)`。
    /// 调研过的成品里**没有任何一家做位移过冲** —— AMLL 是 ease-out 保持、
    /// HyperLyrics 是单调 easeOutQuint、am-lyrics 是峰值后回落、YouLyPlus 是
    /// 1s ease。过冲是我从 KaraokeText 的"衰减余弦"推出来的，方向错了。
    private func addBounceAnimation(
        wordIndex: Int,
        timing: [WordTimingResolver.WordTiming],
        axis: WordByWordAxis
    ) {
        guard timing.indices.contains(wordIndex) else { return }
        let word = timing[wordIndex]
        let start = Double(word.startMs) / 1000
        let end = Double(word.endMs) / 1000
        guard end > start else { return }

        // 回落的结束时刻：下一个词开始，或至少给 0.2s 让回落看得见。
        // 必须**早于**遮罩跳到下一个词，否则回落会被截断成一次跳变。
        let fallEnd: Double
        if timing.indices.contains(wordIndex + 1) {
            let nextStart = Double(timing[wordIndex + 1].startMs) / 1000
            fallEnd = max(end, min(nextStart, max(end, start + 0.2)))
        } else {
            fallEnd = end + 0.2
        }

        let total = max(0.01, fallEnd - start)
        let riseEnd = min(0.85, max(0.02, (end - start) * 0.35 / total))
        let maxOffset = -bounceHeight

        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = [0, maxOffset, maxOffset, 0] as [CGFloat]
        // 第三帧必须与末帧分开一点，否则"保持结束"与"回落结束"是同一时刻、
        // 会被 Core Animation 合并掉，回落那一段就不存在了。
        animation.keyTimes = [0, NSNumber(value: riseEnd), NSNumber(value: 0.999), 1]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),      // 抬起：先快后慢，无过冲
            CAMediaTimingFunction(name: .linear),       // 保持：单调，不做振荡
            CAMediaTimingFunction(name: .easeInEaseOut), // 回落：对称收尾
        ]
        animation.duration = total
        animation.calculationMode = .cubic
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both

        // `start` 是**播放进度**（秒），不是系统时钟。先把当前播放进度由锚点
        // 求出，再换算到 CACurrentMediaTime 时基，否则 beginTime 没有意义。
        let now = CACurrentMediaTime()
        let positionNow = anchor?.position ?? start
        animation.beginTime = now - max(0, positionNow - start)

        bounceLabel.layer.add(animation, forKey: KaraokeLineLabel.bounceAnimationKey)
    }

    private static let bounceAnimationKey = "WordByWordBounce"

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
            // 遮罩**宽度固定**（行宽 + 羽化），位置随推进前缘移动。
            // 宽度不参与动画 → locations 百分比恒定 → 羽化是一个常数像素值。
            let rowWidth = max(1, rowWidths[row])
            let width = rowWidth + feather
            layer.position = CGPoint(x: -width, y: CGFloat(row) * lineHeight + lineHeight / 2)
            layer.bounds = CGRect(x: 0, y: 0, width: width, height: lineHeight)

            layer.startPoint = CGPoint(x: 0, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 0.5)
            layer.locations = KaraokeMaskGeometry.locations(rowWidth: rowWidth, feather: feather)
            layer.colors = KaraokeMaskGeometry.colors()

            container.addSublayer(layer)
            rowMasks.append(layer)
        }

        // 行数一致性：轴的行数、行宽数量、行偏移数量必须对齐，
        // 否则遮罩子层会与关键帧的 widths 数量错位。
        assert(rowCount == rowWidths.count, "axis row count mismatch")

        litLabel.layer.mask = container
        maskContainer = container
    }

    /// 跳动状态自检（粘进日志便于定位「某个词不跳」）。
    var bounceDiagnostics: String {
        guard bounceHeight > 0 else { return "bounce=off" }
        let emphasized = cachedVariant?.emphasizedWords.sorted() ?? []
        let descriptions = bounceSpans.map { group -> String in
            group.first.map { "r\($0.row)x=\(Int($0.x))w=\(Int($0.width))" } ?? "empty"
        }
        return "bounce=h\(String(format: "%.1f", bounceHeight)) "
            + "emph=\(emphasized) active=\(activeBounceWord) "
            + "spans=[\(descriptions.joined(separator: ","))]"
    }

    private static let fillAnimationKey = "WordByWordFill"
    private static let positionAnimationKey = "WordByWordFillPosition"

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
    /// 够「长」、值得上逐字位移的词下标。见 `WordTimingResolver.shouldEmphasize`。
    var emphasizedWords: Set<Int>
    var duration: TimeInterval { stops.duration }
    var stopCount: Int { stops.stops.count }
}
