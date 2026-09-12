import Foundation

// 移植自 MeloX `MeloX/Core/Lyrics/LyricFocusCascadePlanner.swift`（GPL-3.0）。

/// 焦点级联的纯时间规划器。合法计划保证：时间有限且非负、延迟单调不减、
/// 时长单调不增、且在 `availableDuration` 内完成。
enum LyricFocusCascadePlanner {
    private static let maximumMinimumCatchUpDuration: TimeInterval = 0.18

    static func lineTimings(
        maximumLineOrder: Int,
        delayPerLine: TimeInterval,
        delayIncreasePerLine: TimeInterval,
        followingLineBaseDelay: TimeInterval,
        catchUpCompletionRatio: Double,
        availableDuration: TimeInterval
    ) -> [LyricFocusCascadeLineTiming]? {
        guard maximumLineOrder >= 0,
              delayPerLine.isFinite,
              delayPerLine >= 0,
              delayIncreasePerLine.isFinite,
              delayIncreasePerLine >= 0,
              followingLineBaseDelay.isFinite,
              followingLineBaseDelay >= 0,
              catchUpCompletionRatio.isFinite,
              availableDuration.isFinite,
              availableDuration > 0 else {
            return nil
        }

        let ratio = min(max(catchUpCompletionRatio, 0), 1)
        let minimumCatchUpDuration = min(
            maximumMinimumCatchUpDuration,
            availableDuration * 0.5
        )
        let catchUpCompletion = min(
            max(availableDuration * ratio, minimumCatchUpDuration),
            availableDuration
        )
        let maximumDelay = max(
            catchUpCompletion - minimumCatchUpDuration,
            0
        )
        let rawDelays = (0...maximumLineOrder).map { lineOrder in
            rawDelay(
                lineOrder: lineOrder,
                delayPerLine: delayPerLine,
                delayIncreasePerLine: delayIncreasePerLine,
                followingLineBaseDelay: followingLineBaseDelay
            )
        }
        let maximumRawDelay = rawDelays.last ?? 0

        var previousDelay: TimeInterval = 0
        return rawDelays.enumerated().map { lineOrder, rawDelay in
            guard lineOrder > 0 else {
                return LyricFocusCascadeLineTiming(
                    delay: 0,
                    duration: availableDuration
                )
            }

            let fittedDelay: TimeInterval
            if maximumRawDelay > maximumDelay,
               maximumRawDelay > 0 {
                fittedDelay = rawDelay / maximumRawDelay * maximumDelay
            } else {
                fittedDelay = rawDelay
            }
            let delay = min(
                max(fittedDelay, previousDelay),
                maximumDelay
            )
            previousDelay = delay
            return LyricFocusCascadeLineTiming(
                delay: delay,
                duration: max(catchUpCompletion - delay, 0)
            )
        }
    }

    private static func rawDelay(
        lineOrder: Int,
        delayPerLine: TimeInterval,
        delayIncreasePerLine: TimeInterval,
        followingLineBaseDelay: TimeInterval
    ) -> TimeInterval {
        guard lineOrder > 0 else { return 0 }

        let order = Double(lineOrder)
        let accumulatedIncrease = order * max(order - 1, 0) / 2
        let linearDelay = finiteProduct(order, delayPerLine)
        let increasingDelay = finiteProduct(
            accumulatedIncrease,
            delayIncreasePerLine
        )
        return finiteSum(
            followingLineBaseDelay,
            finiteSum(linearDelay, increasingDelay)
        )
    }

    private static func finiteProduct(
        _ lhs: Double,
        _ rhs: Double
    ) -> Double {
        let product = lhs * rhs
        return product.isFinite ? product : .greatestFiniteMagnitude
    }

    private static func finiteSum(
        _ lhs: Double,
        _ rhs: Double
    ) -> Double {
        let sum = lhs + rhs
        return sum.isFinite ? sum : .greatestFiniteMagnitude
    }
}
