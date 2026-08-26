import Foundation

struct LyricsOptions: Codable, Hashable {
    var musixmatchLanguage: String
    var lrclibUrl: String
    var geniusFallback: Bool
    var hideOnError: Bool
}
