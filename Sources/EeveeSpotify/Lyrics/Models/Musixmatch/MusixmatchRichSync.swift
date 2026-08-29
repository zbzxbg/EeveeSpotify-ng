import Foundation

/// Musixmatch `track.richsync.get` 返回的 `richsync_body`（JSON 字符串）行结构。
/// 时间单位：秒；`l` 内每个词的 `o` 为相对该行 `ts` 的偏移秒数。
struct MusixmatchRichSyncLine: Decodable {
    var ts: Double
    var te: Double
    var x: String
    var l: [MusixmatchRichSyncWord]
}

struct MusixmatchRichSyncWord: Decodable {
    var c: String
    var o: Double
}
