import Foundation

// 移植自 MeloX `MeloX/Core/Lyrics/LyricVocalDurationEstimator.swift`（GPL-3.0）。

/// LRC 这类只有行级时间的来源没有「唱完」时间戳。
/// 这里按可见字数估一个保守的演唱时长，用于给出「伪逐字」时间轴与间奏判定。
///
/// ⚠️ MeloX 原始公式是「每字 0.32s，钳到 [2, 8] 秒」，不分语种。
/// 对本项目的中英混排歌词，这个系数只作为**兜底**使用：
/// 真正有逐字时间轴的来源（网易 yrc / Musixmatch richsync / Spicy / AMLL）不会走到这里。
enum LyricVocalDurationEstimator {
    static func estimatedDuration(for text: String) -> TimeInterval {
        let visibleCharacterCount = text.filter { !$0.isWhitespace }.count
        return min(max(Double(visibleCharacterCount) * 0.32, 2), 8)
    }
}
