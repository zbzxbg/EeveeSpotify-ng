import Foundation

// 移植自 MeloX `MeloX/Core/Lyrics/LyricPlaybackTimeline.swift`（GPL-3.0）。
//
// 纯逻辑，无 UI 依赖。这是「当前唱到哪一行 / 焦点归谁」的唯一判定入口，
// 渲染层只消费它的输出。

struct LyricPlaybackPosition: Equatable {
    let highlightedLyricID: LyricLine.ID?
    let activeLyricIDs: Set<LyricLine.ID>
    let nextTransitionTime: TimeInterval?
}

struct LyricFocusCascadeLineTiming: Equatable {
    let delay: TimeInterval
    let duration: TimeInterval
}

struct LyricFocusCascadeTiming: Equatable {
    let lineTimingsByLineOrder: [LyricFocusCascadeLineTiming]
    let usesBounce: Bool

    func lineTiming(for lineOrder: Int) -> LyricFocusCascadeLineTiming {
        guard !lineTimingsByLineOrder.isEmpty else {
            return LyricFocusCascadeLineTiming(delay: 0, duration: 0)
        }
        let index = min(
            max(lineOrder, lineTimingsByLineOrder.startIndex),
            lineTimingsByLineOrder.index(before: lineTimingsByLineOrder.endIndex)
        )
        return lineTimingsByLineOrder[index]
    }
}

enum LyricPlaybackTimeline {
    static func position(
        at playbackTime: TimeInterval,
        in lyrics: [LyricLine]
    ) -> LyricPlaybackPosition {
        guard !lyrics.isEmpty else {
            return LyricPlaybackPosition(
                highlightedLyricID: nil,
                activeLyricIDs: [],
                nextTransitionTime: nil
            )
        }

        var lowerBound = lyrics.startIndex
        var upperBound = lyrics.endIndex
        while lowerBound < upperBound {
            let middleIndex = lowerBound + (upperBound - lowerBound) / 2
            if lyrics[middleIndex].time <= playbackTime {
                lowerBound = middleIndex + 1
            } else {
                upperBound = middleIndex
            }
        }

        let latestStartedLyricID = lowerBound > lyrics.startIndex
            ? lyrics[lyrics.index(before: lowerBound)].id
            : nil
        var activeLyrics = lyrics[..<lowerBound].filter { line in
            guard line.time <= playbackTime else { return false }
            switch line.timingKind {
            case .precise:
                guard let duration = line.duration, duration > 0 else {
                    return line.id == latestStartedLyricID
                }
                return playbackTime < line.time + duration
            case .lineSynchronized:
                return line.id == latestStartedLyricID
            }
        }
        if activeLyrics.isEmpty,
           let latestStartedLyricID,
           let highlightedLine = lyrics[..<lowerBound].last(where: {
               $0.id == latestStartedLyricID
           }) {
            activeLyrics = [highlightedLine]
        }
        let highlightedLyricID = activeLyrics.last(where: {
            $0.agent?.alignment != .flipped
        })?.id ?? activeLyrics.last.map {
            inheritedFocusLyricID(
                for: $0,
                in: lyrics[..<lowerBound]
            )
        } ?? latestStartedLyricID
        let activeLyricIDs = Set(activeLyrics.map(\.id))
        let nextStartTime = lowerBound < lyrics.endIndex
            ? lyrics[lowerBound].time
            : nil
        let nextEndTime = activeLyrics.compactMap { line -> TimeInterval? in
            guard line.timingKind == .precise,
                  let duration = line.duration,
                  duration > 0 else {
                return nil
            }
            let end = line.time + duration
            return end > playbackTime ? end : nil
        }.min()
        let nextTransitionTime = [nextStartTime, nextEndTime]
            .compactMap { $0 }
            .min()
        return LyricPlaybackPosition(
            highlightedLyricID: highlightedLyricID,
            activeLyricIDs: activeLyricIDs,
            nextTransitionTime: nextTransitionTime
        )
    }

    /// Apple Music 把重叠的行保留在「已选行集合」里：某一行还在唱时另一条
    /// 副声部行开始，它会加入当前选择而不是抢走滚动焦点；副声部单独开始才接管焦点。
    private static func inheritedFocusLyricID(
        for target: LyricLine,
        in startedLyrics: ArraySlice<LyricLine>
    ) -> LyricLine.ID {
        typealias FocusEntry = (
            endTime: TimeInterval,
            ownerID: LyricLine.ID,
            isPrimary: Bool
        )
        var overlappingEntries: [FocusEntry] = []

        for line in startedLyrics {
            overlappingEntries.removeAll {
                $0.endTime <= line.time
            }

            let isPrimary = line.agent?.alignment != .flipped
            let ownerID: LyricLine.ID
            if isPrimary {
                ownerID = line.id
            } else if let primaryEntry = overlappingEntries.last(where: {
                $0.isPrimary
            }) {
                ownerID = primaryEntry.ownerID
            } else {
                ownerID = overlappingEntries.last?.ownerID ?? line.id
            }

            if line.id == target.id {
                return ownerID
            }

            guard line.timingKind == .precise,
                  let duration = line.duration,
                  duration > 0 else {
                continue
            }
            overlappingEntries.append(
                (
                    endTime: line.time + duration,
                    ownerID: ownerID,
                    isPrimary: isPrimary
                )
            )
        }

        return target.id
    }

    static func focusAnimationDuration(
        for highlightedLyricID: LyricLine.ID?,
        in lyrics: [LyricLine]
    ) -> TimeInterval {
        guard let availableDuration = availableFocusDuration(
            for: highlightedLyricID,
            in: lyrics
        ) else {
            return 0.3
        }

        return min(max(availableDuration * 0.35, 0.05), 0.3)
    }

    static func focusCascadeAnimationDuration(
        baseDuration: TimeInterval,
        preferredDuration: TimeInterval
    ) -> TimeInterval {
        let duration = baseDuration.isFinite ? max(baseDuration, 0) : 0
        let configuredDuration = preferredDuration.isFinite
            ? max(preferredDuration, 0)
            : 0
        return max(duration, configuredDuration)
    }

    static func focusCascadeTiming(
        maximumLineOrder: Int,
        preferredDelayPerLine: TimeInterval,
        preferredDelayIncreasePerLine: TimeInterval,
        followingLineBaseDelay: TimeInterval,
        preferredCatchUpCompletionRatio: Double,
        focusColorLeadTime: TimeInterval,
        baseAnimationDuration: TimeInterval,
        preferredAnimationDuration: TimeInterval,
        prefersBounce: Bool,
        snapThreshold: TimeInterval,
        remainingDuration: TimeInterval?
    ) -> LyricFocusCascadeTiming? {
        guard maximumLineOrder >= 0,
              preferredDelayPerLine.isFinite,
              preferredDelayPerLine >= 0,
              preferredDelayIncreasePerLine.isFinite,
              preferredDelayIncreasePerLine >= 0,
              followingLineBaseDelay.isFinite,
              followingLineBaseDelay >= 0,
              preferredCatchUpCompletionRatio.isFinite,
              focusColorLeadTime.isFinite,
              baseAnimationDuration.isFinite,
              baseAnimationDuration > 0 else {
            return nil
        }
        let delayPerLine = max(preferredDelayPerLine, 0)
        let delayIncreasePerLine = max(preferredDelayIncreasePerLine, 0)
        let baseDelayForFollowingLines = max(followingLineBaseDelay, 0)
        let catchUpCompletionRatio = min(
            max(preferredCatchUpCompletionRatio, 0),
            1
        )
        let fullAnimationDuration = focusCascadeAnimationDuration(
            baseDuration: baseAnimationDuration,
            preferredDuration: preferredAnimationDuration
        )
        guard let fullLineTimings = LyricFocusCascadePlanner.lineTimings(
            maximumLineOrder: maximumLineOrder,
            delayPerLine: delayPerLine,
            delayIncreasePerLine: delayIncreasePerLine,
            followingLineBaseDelay: baseDelayForFollowingLines,
            catchUpCompletionRatio: catchUpCompletionRatio,
            availableDuration: fullAnimationDuration
        ) else {
            return nil
        }
        let fullTiming = LyricFocusCascadeTiming(
            lineTimingsByLineOrder: fullLineTimings,
            usesBounce: prefersBounce
        )
        guard let remainingDuration, remainingDuration.isFinite else {
            return fullTiming
        }

        let availableDuration = remainingDuration - max(focusColorLeadTime, 0)
        let effectiveSnapThreshold = snapThreshold.isFinite
            ? max(snapThreshold, 0)
            : 0
        guard availableDuration.isFinite,
              availableDuration > 0,
              availableDuration >= effectiveSnapThreshold else {
            return nil
        }
        // 在下一句歌词抢走焦点之前结束这次级联，避免密集时间轴让下方各行永远追不上。
        let availableAnimationDuration = min(
            fullAnimationDuration,
            availableDuration
        )
        guard let availableLineTimings = LyricFocusCascadePlanner.lineTimings(
            maximumLineOrder: maximumLineOrder,
            delayPerLine: delayPerLine,
            delayIncreasePerLine: delayIncreasePerLine,
            followingLineBaseDelay: baseDelayForFollowingLines,
            catchUpCompletionRatio: catchUpCompletionRatio,
            availableDuration: availableAnimationDuration
        ) else {
            return nil
        }
        return LyricFocusCascadeTiming(
            lineTimingsByLineOrder: availableLineTimings,
            usesBounce:
                prefersBounce
                    && availableAnimationDuration >= fullAnimationDuration
        )
    }

    static func remainingFocusDuration(
        for highlightedLyricID: LyricLine.ID?,
        at playbackTime: TimeInterval,
        in lyrics: [LyricLine]
    ) -> TimeInterval? {
        guard let highlightedLyricID,
              playbackTime.isFinite,
              let index = lyrics.firstIndex(where: { $0.id == highlightedLyricID }) else {
            return nil
        }
        let followingIndex = lyrics.index(after: index)
        guard followingIndex < lyrics.endIndex else { return nil }

        let remainingDuration = lyrics[followingIndex].time - playbackTime
        guard remainingDuration.isFinite else { return nil }
        return max(remainingDuration, 0)
    }

    private static func availableFocusDuration(
        for highlightedLyricID: LyricLine.ID?,
        in lyrics: [LyricLine]
    ) -> TimeInterval? {
        guard let highlightedLyricID,
              let index = lyrics.firstIndex(where: { $0.id == highlightedLyricID }) else {
            return nil
        }

        let followingIndex = lyrics.index(after: index)
        let availableDuration = followingIndex < lyrics.endIndex
            ? lyrics[followingIndex].time - lyrics[index].time
            : lyrics[index].duration
        guard let availableDuration,
              availableDuration.isFinite,
              availableDuration > 0 else {
            return nil
        }
        return availableDuration
    }
}
