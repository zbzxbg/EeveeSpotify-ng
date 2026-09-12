import Foundation

// MARK: - AMLL HTTP API 响应模型
//
// 对应 https://api.amll.dev 的原生接口（/v1/lyrics/get、/v1/lyrics/search）。
// 官方 OpenAPI 规范：https://amll.dev/api/ttml/openapi.yaml
//
// 响应统一包在 ApiResponse<T> 里：成功是 {"status":200,"data":T}，
// 失败是 {"status":4xx/5xx,"error":"...","message":"..."}。
// 这里不解成泛型，直接按字段可选解析，避免为一个接口引入泛型解码的复杂度。

/// `/v1/lyrics/search` 与 `/v1/lyrics/get` 共用的歌曲条目。
/// 搜索接口里 `lyrics` 固定为 null，只有 `get` 接口会带上完整 TTML。
struct AmllSongItem: Decodable {
    var id: Int64?
    var filename: String?

    var musicNames: [String]?
    var artistNames: [String]?
    var albumNames: [String]?

    var ncmMusicIds: [String]?
    var qqMusicIds: [String]?
    var appleMusicIds: [String]?
    var spotifyIds: [String]?
    var isrcs: [String]?

    var authorIds: [String]?
    var authorUsernames: [String]?

    /// TTML 正文。仅 `/v1/lyrics/get` 返回。
    var lyrics: String?

    /// 歌词主要贡献者的 GitHub 用户名（取第一个）。
    /// AMLL 仓库 README 明确希望下游展示歌词作者信息，这里用于 providedBy 署名。
    var primaryAuthorUsername: String? {
        authorUsernames?.first(where: { !$0.isEmpty })
    }
}

/// `/v1/lyrics/search` 的分页元信息。
struct AmllPagination: Decodable {
    var page: Int?
    var pageSize: Int?
    var total: Int?
    var totalPages: Int?
    var hasMore: Bool?
}

/// `/v1/lyrics/search` 的 data 载荷。
struct AmllSearchPayload: Decodable {
    var items: [AmllSongItem]?
    var pagination: AmllPagination?
}

/// 错误响应体（400 / 404 / 429 / 502）。
struct AmllErrorPayload: Decodable {
    var status: Int?
    var error: String?
    var message: String?
}
