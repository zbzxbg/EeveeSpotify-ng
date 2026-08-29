import Foundation

/// 词级（逐字/逐音节）时间轴。
/// 仅当「开启逐字歌词」且上游返回词级数据时填充；
/// 注入 Spotify 的最终输出仍是行级（本字段暂不映射到 protobuf）。
struct LyricsWordDto {
    var text: String
    var startMs: Int
    var endMs: Int? = nil
}
