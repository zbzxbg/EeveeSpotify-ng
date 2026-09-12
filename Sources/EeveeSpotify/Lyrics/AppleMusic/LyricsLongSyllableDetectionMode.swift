import Foundation

// 移植自 MeloX `MeloX/Core/Settings/Lyrics/LyricsLongSyllableDetectionMode.swift`（GPL-3.0）。

/// 长音检测的统计口径：按「整词」还是按「单字」判断时长。
enum LyricsLongSyllableDetectionMode: String, CaseIterable, Sendable {
    case word
    case character

    var description: String {
        switch self {
        case .word: return "word"
        case .character: return "character"
        }
    }
}
