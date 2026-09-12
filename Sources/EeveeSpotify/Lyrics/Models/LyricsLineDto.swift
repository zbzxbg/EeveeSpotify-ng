import Foundation

struct LyricsLineDto {
    var content: String
    var offsetMs: Int?
    var words: [LyricsWordDto]? = nil
    /// 背景人声/副唱（目前只有 AMLL 会给出）。
    ///
    /// 它**不属于** `content` / `words`：那些是主词序列。副唱与主词时间重叠，
    /// 由渲染层单独画一小行，而不是顺序拼进主歌。
    var backgroundVocal: LyricsBackgroundVocalDto? = nil
}
