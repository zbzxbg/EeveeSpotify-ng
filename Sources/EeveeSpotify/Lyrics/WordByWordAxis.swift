import Foundation
import CoreGraphics
import CoreText
import UIKit

// MARK: - 逐词填充的「展平轴」(unrolled axis)
//
// 目标：把一行（可能换行的）歌词映射到一条单调递增的一维标量轴上，
// 使「已经唱到哪个字」可以用一个数字表达。
//
//   rowAdvance[r] = max(rowWidth[r], rowWidth[r-1])
//   rowStart[r]   = rowStart[r-1] + rowAdvance[r-1]
//   unrolled(字符下标 i) = rowStart[row(i)] + 该字符在本行内的 x 偏移
//
// rowAdvance 必须用**跨行累积宽度**而非本行实际宽度：换行时下一行的起点
// 在上一行的右端（overflowing inline box 语义），
// 所以「整行填满」这一刻的 unrolled 值等于本行累积宽度。
//
// 为什么用 boundingRect 而不是 Core Text 逐 glyph：
//   测的是和 UILabel 完全相同的字符串与属性，天然与真实渲染一致。
//   代价是要自己还原断行位置（见 splitRows），换来的是零字体/排版偏差。
//
// ⚠️ boundingRect 返回的是**包围盒**，其 width 是「所有行中最宽那一行」，
// 不是各行宽度之和；height 才是累加值。本文件正是靠 height 的阶梯
// 定位断行，再逐行取 width。这一点与 KaraokeText 用 TextRenderer
// 直接拿 SwiftUI layout 不同——那边不需要还原，我们这边必须还原。

struct WordByWordAxis {

    /// 轴合法性自检结果（打日志用）。
    struct Diagnostics {
        var rows = 0
        var rowWidths: [CGFloat] = []
        var rowAdvances: [CGFloat] = []
        var boundaryCount = 0
        /// 词边界是否单调不减 —— 为 false 说明还原公式在该行数据上不成立。
        var monotonic = true

        var summary: String {
            let widths = rowWidths.map { String(format: "%.0f", $0) }.joined(separator: ",")
            let advances = rowAdvances.map { String(format: "%.0f", $0) }.joined(separator: ",")
            return "rows=\(rows) rowW=[\(widths)] rowAdv=[\(advances)] "
                + "bounds=\(boundaryCount) monotonic=\(monotonic)"
        }
    }

    /// 实际用于渲染的展示文本（由词文本拼成，与 label.text 完全一致）。
    let displayText: String
    let containerWidth: CGFloat

    private let text: NSString
    /// 建 CTLine 时复用同一字体，保证下标↔偏移换算与 label 排版一致。
    private let font: UIFont
    private let rowStart: [CGFloat]
    private let rowAdvance: [CGFloat]
    private let measuredRowWidths: [CGFloat]
    private let rowRanges: [NSRange]

    private var lineCache: [Int: CTLine] = [:]
    private(set) var diagnostics = Diagnostics()

    private static let heightEpsilon: CGFloat = 0.25

    // MARK: 构建

    /// containerWidth 必须是 label 的**已布局**宽度（bounds.width）；
    /// 宽度为 0（尚未布局）时返回 nil，调用方应回退到行级着色。
    init?(displayText: String, font: UIFont, containerWidth: CGFloat) {
        guard containerWidth > 1 else { return nil }

        // 末尾空白会让 boundingRect 多算一个「幽灵行」，先裁掉。
        let trimmed = displayText.replacingOccurrences(
            of: "[\\s\\u3000]+$",
            with: "",
            options: .regularExpression
        )
        guard !trimmed.isEmpty else { return nil }

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let width = containerWidth.rounded(.down)

        func measure(_ string: String) -> CGSize {
            (string as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs,
                context: nil
            ).size
        }

        let ns = trimmed as NSString
        let heightForOneRow = WordByWordAxis.singleRowHeight(measure("X").height)
        guard heightForOneRow > 1 else { return nil }

        let ranges = WordByWordAxis.splitRows(
            ns: ns,
            rowHeight: heightForOneRow,
            measure: measure
        )

        // 逐行取实际宽度 → 还原跨行累积宽度。
        var widths: [CGFloat] = []
        for range in ranges {
            let raw = measure(ns.substring(with: range)).width
            widths.append(min(width, max(1, raw)))
        }
        if widths.isEmpty {
            widths = [min(width, max(1, measure(trimmed).width))]
        }

        var starts: [CGFloat] = []
        var advances: [CGFloat] = []
        var cursor: CGFloat = 0
        for rowWidth in widths {
            let previous = advances.last ?? rowWidth
            let advance = max(rowWidth, previous)
            starts.append(cursor)
            advances.append(advance)
            cursor += advance
        }

        self.displayText = displayText
        self.containerWidth = containerWidth
        self.text = ns
        self.font = font
        self.rowStart = starts
        self.rowAdvance = advances
        self.measuredRowWidths = widths
        self.rowRanges = ranges.isEmpty
            ? [NSRange(location: 0, length: ns.length)]
            : ranges

        var diag = Diagnostics()
        diag.rows = advances.count
        diag.rowWidths = widths
        diag.rowAdvances = advances
        self.diagnostics = diag

        writeDebugLog("[WordByWord/Axis] \"\(trimmed.prefix(24))\" \(diagnostics.summary)")
    }

    var rows: Int { rowAdvance.count }
    var isEmpty: Bool { rowAdvance.isEmpty }
    /// 每行的实际测量宽度（遮罩子层的宽度上限）。
    var rowWidths: [CGFloat] { measuredRowWidths }
    /// 每一行在展平轴上的起点与累积长度 —— 是轴的**唯一权威来源**。
    /// 关键帧构建必须用它，而不是按公式重算一份，否则两处公式一旦漂移，
    /// 填充位置会静默错位（不崩溃、不报错，只是看起来偏了）。
    var rowOffsets: (starts: [CGFloat], advances: [CGFloat]) { (rowStart, rowAdvance) }

    var totalWidth: CGFloat {
        guard let lastStart = rowStart.last, let lastAdvance = rowAdvance.last else { return 0 }
        return lastStart + lastAdvance
    }

    // MARK: 词边界

    /// 把「每个词在 displayText 里的 NSRange」换算成展平轴上的边界。
    /// 返回数组长度为 words.count + 1，首元素固定为 0。
    ///
    /// 用于构建 CAKeyframeAnimation 的 values —— 不再是「词宽等比缩放」，
    /// 而是同一字符串的真实测量值，因此不存在 kerning / 断行累积误差。
    ///
    /// 每个词取「首字符左缘 → 末字符右缘」：
    ///   词前的空格不在区间内，因此唱针在词间隙会停住 —— 这与逐词时间轴
    ///   本身的语义一致（间隙期间没有音，填色就不该推进）。
    func boundaries(forWordRanges ranges: [NSRange]) -> [CGFloat] {
        var result: [CGFloat] = [0]
        var last: CGFloat = 0

        for range in ranges {
            guard range.location >= 0, range.location < text.length else {
                result.append(last)
                continue
            }
            let startIndex = range.location
            let endIndex = min(text.length, max(startIndex + 1, range.location + range.length))

            let head = max(last, unrolledHeadEdge(ofCharacterAt: startIndex))
            let tail = max(head, unrolledTailEdge(ofCharacterAt: endIndex - 1))
            result.append(tail)
            last = tail
        }

        var diag = diagnostics
        diag.boundaryCount = result.count
        diag.monotonic = zip(result, result.dropFirst()).allSatisfy { $0 <= $1 }
        diagnostics = diag
        if !diag.monotonic {
            writeDebugLog("[WordByWord/Axis] ⚠️ non-monotonic boundaries — \(diag.summary)")
        }
        return result
    }

    // MARK: 字符 ↔ 展平轴 互转
    //
    // 用 Core Text 的 `CTLineGetOffsetForStringIndex` 取字符**左缘**，
    // 再借「下一字符的左缘」得到本字符的右缘。
    // 这样得到的字符区间是半开区间 [head(i), head(i+1))，
    // 对 CJK（一个字 = 两个 UTF-16 单元）和 emoji 代理对都天然正确 ——
    // 直接用 `CTLineGetStringIndexForPosition` 反查会在「位置正好落在
    // 字符边界」时归属不定，代理对更难处理。

    /// 字符 i 在展平轴上的左缘。
    func unrolledHeadEdge(ofCharacterAt index: Int) -> CGFloat {
        guard index >= 0, index < text.length else { return 0 }
        let row = rowIndex(forCharacterAt: index)
        let offset = characterOffsetInRow(index, row: row)
        return rowStart[row] + offset
    }

    /// 字符 i 在展平轴上的右缘。
    func unrolledTailEdge(ofCharacterAt index: Int) -> CGFloat {
        guard index >= 0, index < text.length else { return 0 }
        // 优先用下一个字符的左缘；index 已是本行最后一个字符时退到本行行尾。
        if index + 1 <= text.length,
           rowIndex(forCharacterAt: index + 1) == rowIndex(forCharacterAt: index) {
            return unrolledHeadEdge(ofCharacterAt: index + 1)
        }
        let row = rowIndex(forCharacterAt: index)
        let line = ctLine(forRow: row)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        )
        guard lineWidth > 0 else { return unrolledHeadEdge(ofCharacterAt: index) }
        return rowStart[row] + min(lineWidth, rowAdvance[row])
    }

    /// 字符 i 落在第几行。
    /// 注意允许 `index == text.length`（`unrolledTailEdge` 会用它判断
    /// 「下一个字符是否还在同一行」），因此这里只按行区间上界裁剪，
    /// 不把下标硬压到 length - 1。
    private func rowIndex(forCharacterAt index: Int) -> Int {
        let clamped = max(0, index)
        for row in rowRanges.indices {
            let range = rowRanges[row]
            if clamped < range.location + range.length { return row }
        }
        return max(0, rowRanges.count - 1)
    }

    /// 字符 i 在本行内的 x 偏移。
    /// `rowRanges[row].location` 在每次调用时重算 Core Text 的字符串下标基准，
    /// 因此这里统一用全局下标减去本行起点。
    private func characterOffsetInRow(_ index: Int, row: Int) -> CGFloat {
        let range = rowRanges[row]
        let localIndex = max(0, index - range.location)
        let line = ctLine(forRow: row)
        return CGFloat(CTLineGetOffsetForStringIndex(line, localIndex, nil))
    }

    /// 只为该行文本建立 CTLine —— 仅用于位置↔下标互转，不参与绘制，
    /// 因此排版细节（换行留白等）不影响正确性。
    private func ctLine(forRow row: Int) -> CTLine {
        if let cached = lineCache[row] { return cached }
        let safeRow = min(max(0, row), rowRanges.count - 1)
        let substring = text.substring(with: rowRanges[safeRow])
        let attributed = NSAttributedString(string: substring, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        lineCache[row] = line
        return line
    }

    // MARK: 断行还原

    /// 靠 boundingRect 的 height 阶梯定位断行。
    ///
    /// 同一字体下行高恒定，故 `height(前 n 行) == n * rowHeight`：
    ///   - 第一个使 height 超过 1 行的下标 → 第 1 行的结束
    ///   - 第一个使 height 超过 2 行的下标 → 第 2 行的结束
    /// 二分查找，每行 O(log n) 次测量。
    private static func splitRows(
        ns: NSString,
        rowHeight: CGFloat,
        measure: (String) -> CGSize
    ) -> [NSRange] {
        let length = ns.length
        guard length > 0 else { return [] }

        func rowCount(upTo location: Int) -> Int {
            let clamped = max(0, min(length, location))
            let substring = clamped == 0 ? "" : ns.substring(to: clamped)
            let height = measure(substring).height
            guard height > 0 else { return 1 }
            // +0.25 容差：height 应为 rowHeight 的整数倍。
            return max(1, Int(((height + heightEpsilon) / rowHeight).rounded(.down)))
        }

        guard rowCount(upTo: length) > 1 else {
            return [NSRange(location: 0, length: length)]
        }

        var ranges: [NSRange] = []
        var cursor = 0
        var target = 2

        while cursor < length {
            if rowCount(upTo: length) < target {
                ranges.append(NSRange(location: cursor, length: length - cursor))
                break
            }

            var low = cursor
            var high = length
            var iterations = 0
            while high - low > 1 && iterations < 24 {
                let mid = (low + high) / 2
                if rowCount(upTo: mid) >= target {
                    high = mid
                } else {
                    low = mid
                }
                iterations += 1
            }

            // 收敛后 high 是「行数首次达到 target」的最小下标；
            // 回退掉换行点前的空白（换行本身吃掉一个空格）。
            var cut = high
            while cut > cursor, isWhitespace(ns.character(at: cut - 1)) {
                cut -= 1
            }
            if cut <= cursor { cut = high }

            ranges.append(NSRange(location: cursor, length: max(1, cut - cursor)))
            cursor = cut
            target += 1
        }

        return ranges
    }

    private static func singleRowHeight(_ raw: CGFloat) -> CGFloat {
        guard raw > 0 else { return 0 }
        return max(1, (raw * 100).rounded() / 100)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

// MARK: - 填充关键帧

/// 一行歌词的填充关键帧数据，直接喂给 `CAKeyframeAnimation`。
struct WordByWordFillStops {

    /// 单个停靠点：keyTime 是相对**本段填充时长**的 0...1 比例，
    /// widths 是每一行遮罩子层在该时刻应达到的宽度。
    struct Stop {
        var keyTime: Double
        var widths: [CGFloat]
    }

    var stops: [Stop]
    /// 每行遮罩的最大宽度（动画终点）。
    var rowWidths: [CGFloat]
    var duration: TimeInterval
    var anchorPosition: TimeInterval
    var anchorWallTime: CFTimeInterval

    /// 在给定 keyTime 处的每行宽度（线性插值）——
    /// 用于「立即冻结在当前位置」以及降级到行级时的定位。
    func widths(atKeyTime keyTime: Double) -> [CGFloat] {
        guard let first = stops.first else {
            return [CGFloat](repeating: 0, count: rowWidths.count)
        }
        let clamped = min(1, max(0, keyTime))

        var previous = first
        for stop in stops {
            guard stop.keyTime <= clamped + 1e-9 else {
                let span = stop.keyTime - previous.keyTime
                let ratio = span > 1e-9 ? (clamped - previous.keyTime) / span : 1
                return (0..<rowWidths.count).map { row in
                    let from = previous.widths.indices.contains(row) ? previous.widths[row] : 0
                    let to = stop.widths.indices.contains(row) ? stop.widths[row] : from
                    return from + (to - from) * CGFloat(ratio)
                }
            }
            previous = stop
        }
        return (0..<rowWidths.count).map { row in
            previous.widths.indices.contains(row) ? previous.widths[row] : 0
        }
    }
}

// MARK: - 关键帧构建

enum WordByWordKeyframes {

    /// 词级填充。
    ///
    /// 关键性质：只有**词边界**才是关键帧，Core Animation 的线性插值负责词内推进
    /// —— 这就是那条连续「唱针」的来源，而不是逐词跳变。
    static func wordLevel(
        axis: WordByWordAxis,
        timing: [WordTimingResolver.WordTiming],
        boundaries: [CGFloat],
        rowWidths: [CGFloat],
        segmentStartMs: Int,
        segmentEndMs: Int,
        anchorPosition: TimeInterval
    ) -> WordByWordFillStops? {
        let durationMs = segmentEndMs - segmentStartMs
        guard durationMs > 0,
              !rowWidths.isEmpty,
              timing.count + 1 == boundaries.count,
              !timing.isEmpty else { return nil }

        let duration = Double(durationMs) / 1000
        // 行偏移直接取轴的权威数据（见 rowOffsets 的说明）。
        let rowStarts = axis.rowOffsets.starts

        /// 展平轴坐标 → 每一行应达到的宽度。
        func widths(atUnrolled value: CGFloat) -> [CGFloat] {
            let clamped = min(max(0, value), axis.totalWidth)
            return rowWidths.indices.map { row in
                let width = clamped - rowStarts[row]
                if width <= 0 { return 0 }
                if width >= rowWidths[row] { return rowWidths[row] }
                return width
            }
        }

        var raw: [(time: Double, order: Int, widths: [CGFloat])] = []
        var order = 0

        func append(_ time: Double, _ widths: [CGFloat]) {
            raw.append((min(max(0, time), 1), order, widths))
            order += 1
        }

        append(0, widths(atUnrolled: boundaries[0]))

        for index in timing.indices {
            let word = timing[index]
            let unrolledStart = min(max(0, boundaries[index]), axis.totalWidth)
            let unrolledEnd = min(max(unrolledStart, boundaries[index + 1]), axis.totalWidth)

            append(
                Double(word.startMs - segmentStartMs) / Double(durationMs),
                widths(atUnrolled: unrolledStart)
            )
            append(
                Double(word.endMs - segmentStartMs) / Double(durationMs),
                widths(atUnrolled: unrolledEnd)
            )
        }

        // 时间排序，同一时间保持写入顺序（后写者胜）。
        let sorted = raw.sorted { lhs, rhs in
            lhs.time == rhs.time ? lhs.order < rhs.order : lhs.time < rhs.time
        }

        // keyTimes 必须严格递增：相同时间合并，只保留最后（最完整）的宽度状态。
        var merged: [(time: Double, widths: [CGFloat])] = []
        for entry in sorted {
            if let last = merged.last, abs(last.time - entry.time) < 1e-9 {
                merged[merged.count - 1].widths = entry.widths
            } else {
                merged.append((entry.time, entry.widths))
            }
        }

        // 合并后仍不足两个停靠点 = 时间轴退化（调用方的质量门槛本应拦住，
        // 这里作最后兜底）。**不**在此处退化成「整行线性扫描」——那会让
        // 一条坏数据的行看起来像正常唱过一遍，反而掩盖问题；
        // 返回 nil 交给调用方走明确的行级基例。
        guard merged.count >= 2 else { return nil }

        return WordByWordFillStops(
            stops: merged.map { WordByWordFillStops.Stop(keyTime: $0.time, widths: $0.widths) },
            rowWidths: rowWidths,
            duration: duration,
            anchorPosition: anchorPosition,
            anchorWallTime: CACurrentMediaTime()
        )
    }

    /// 离散填充（行级基例）：没有可用词级时间轴时，整行在某个时刻**一次性**点亮，
    /// 而不是从左到右扫过去。
    ///
    /// 为什么不是线性扫描：连续推进表达的是「这个词正在被唱出来」。
    /// 没有词级时间轴时我们并不知道这一点，用扫描去假装，会让一个只唱了
    /// 半拍的单字行看起来像被拖长了 —— 比直接切换更不诚实。
    /// 单个词的词级数据同理（`isUsableForFill` 要求 >= 2 个词）。
    static func discrete(
        rowWidths: [CGFloat],
        keyTime: Double,
        duration: TimeInterval,
        anchorPosition: TimeInterval
    ) -> WordByWordFillStops {
        let empty = [CGFloat](repeating: 0, count: rowWidths.count)
        let clamped = min(max(0, keyTime), 1)
        // 两个停靠点之间的默认线性插值会让 0→满宽 在 (clamped - 0.02, clamped + 0.02)
        // 内完成，视觉上等同一个快速的横向擦除"snap"，而不是缓慢扫描。
        return WordByWordFillStops(
            stops: [
                WordByWordFillStops.Stop(keyTime: max(0, clamped - 0.02), widths: empty),
                WordByWordFillStops.Stop(keyTime: clamped, widths: rowWidths),
            ],
            rowWidths: rowWidths,
            duration: max(0.001, duration),
            anchorPosition: anchorPosition,
            anchorWallTime: CACurrentMediaTime()
        )
    }
}
