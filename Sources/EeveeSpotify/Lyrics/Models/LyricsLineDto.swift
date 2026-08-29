import Foundation

struct LyricsLineDto {
    var content: String
    var offsetMs: Int?
    var words: [LyricsWordDto]? = nil
}
