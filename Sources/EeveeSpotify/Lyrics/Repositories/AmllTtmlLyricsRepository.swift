import Foundation

// MARK: - AmllTtmlLyricsRepository
//
// AMLL 逐词歌词源（amll.dev）。
//
// ── 数据来源 ──────────────────────────────────────────────────────────────
// 走 AMLL 官方 HTTP API：https://api.amll.dev/v1/lyrics/get?spotifyId=<trackID>
// 单层精确匹配：Spotify Track ID 就是唯一入口，**不做模糊搜索、不做歌名匹配**。
// 拿不到就抛 .noSuchSong 交给既有的 geniusFallback 逻辑，猜错比没有更糟。
//
// 为什么用官方 API 而不是社区镜像：AMLL 的全部镜像站（bikonoo / stevexmh / dimeta /
// GDBA）都是按**网易云 / QQ 音乐 ID** 建索引的，本项目播放上下文里只有 Spotify Track ID，
// 没有镜像可用的 URL 模板。官方 API 是唯一接受 spotifyId 的入口。
//
// ── 为什么不做「时长闸门」──────────────────────────────────────────────────
// TTML 里 <body dur> 与 /v1/lrclib/get 的 duration 字段都是「最后一个歌词时间戳」，
// 不是音频时长（末句唱完到歌曲结束差几十秒属正常）。用它做等值比较是方法错误。
// 身份判据只保留上游可声明的信号：文件内嵌的 spotifyId 命中本曲。
//
// ── 错误分类（关键）──────────────────────────────────────────────────────
// 404 → 库里真没有 → .noSuchSong，静默降级，不弹窗。
// 429（官方限流，单 IP 均值 50 req/s）与 502（OpenAPI 明示「数据源不稳定或索引更新失败」）
//   → 是服务问题不是「没有歌词」，退避重试；连续失败抛错，日志明确区分。
// 这两个状态码不能混进 noSuchSong，否则一次网络抖动就会被当成「这首歌没歌词」。
//
// ── 缓存 ──────────────────────────────────────────────────────────────────
// 官方文档：通过 id / filename 取得的歌词内容永久固定不变，建议长期缓存。
// 这里按 spotifyTrackId 缓存最终 DTO（含质检结论），命中即跳过网络与解析。

class AmllTtmlLyricsRepository: LyricsRepository {

    static let shared = AmllTtmlLyricsRepository()

    /// API 基址。self-host 或走反代时可在设置里改（独立 UserDefault key，
    /// 因为 LyricsOptions 整体存在一个 key 里，加字段会破坏旧数据的解码）。
    static let defaultApiUrl = "https://api.amll.dev"
    static let apiUrlUserDefaultsKey = "ngzhwm_amllApiUrl"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    private let session: URLSession

    private var apiUrl: String {
        let configured = UserDefaults.standard.string(forKey: Self.apiUrlUserDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured, !configured.isEmpty else { return Self.defaultApiUrl }
        // 去掉结尾斜杠，避免拼出 //v1/lyrics/get。
        return configured.hasSuffix("/") ? String(configured.dropLast()) : configured
    }

    private class CachedLyrics {
        let dto: LyricsDto
        init(dto: LyricsDto) { self.dto = dto }
    }

    private let lyricsCache = NSCache<NSString, CachedLyrics>()

    /// 重试策略：最多 2 次尝试，退避 0.5s。
    /// 单源模式下这次调用发生在歌词加载的阻塞路径上（与其它源一致），
    /// 因此重试预算压到最小：只有网络/服务侧错误才重试，404 立即返回。
    private static let maxAttempts = 2
    private static let retryDelays: [TimeInterval] = [0.5]

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let trackId = query.spotifyTrackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trackId.isEmpty else {
            writeDebugLog("[AMLL] empty Spotify track ID — noSuchSong")
            throw LyricsError.noSuchSong
        }

        let cacheKey = trackId as NSString
        if let cached = lyricsCache.object(forKey: cacheKey) {
            writeDebugLog("[AMLL] cache hit for \(trackId)")
            return cached.dto
        }

        writeDebugLog("[AMLL] fetching \"\(query.title)\" - \(query.primaryArtist) (spotifyId \(trackId))")

        let item = try fetchLyricsItem(trackId: trackId)

        guard let ttml = item.lyrics, !ttml.isEmpty else {
            writeDebugLog("[AMLL] response carried no lyrics payload — noSuchSong")
            throw LyricsError.noSuchSong
        }

        let parsed = try AmllTtmlParser.parse(ttml)

        // 身份复核：官方 API 已按 spotifyId 匹配，理论上必然命中；但后端存在
        // 「数据源不稳定 / 索引更新失败」的已知问题，若返回的条目明确登记了
        // Spotify ID 却不含本曲，说明匹配错了 —— 宁可不要。
        if !parsed.spotifyIds.isEmpty, !parsed.spotifyIds.contains(trackId) {
            writeDebugLog(
                "[AMLL] identity check failed — file declares spotifyIds=\(parsed.spotifyIds.prefix(3)) but track is \(trackId)"
            )
            throw LyricsError.noSuchSong
        }

        let dto = AmllLyricsMapper.makeDto(parsed)

        guard !dto.lines.isEmpty else {
            writeDebugLog("[AMLL] mapped to zero line — noSuchSong")
            throw LyricsError.noSuchSong
        }

        logSummary(item: item, parsed: parsed, dto: dto)
        lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey)
        return dto
    }

    // MARK: - 网络

    /// 一次请求的结果。重试判定必须和错误映射写在同一个地方 ——
    /// 否则「哪些错误值得再试」会散落在两层之间，很容易把 502 当成「查无此歌」。
    private enum FetchOutcome {
        case success(AmllSongItem)
        /// 服务侧问题（网络 / 超时 / 429 / 5xx）：值得退避重试，最终失败也不代表「没有歌词」。
        case retryable(reason: String, cause: LyricsError)
        /// 确定性错误（404 / 参数错误 / 解析失败）：已抛出，不重试。
        case fatal(LyricsError)
    }

    private func fetchLyricsItem(trackId: String) throws -> AmllSongItem {
        var lastError: LyricsError = .unknownError

        for attempt in 0..<Self.maxAttempts {
            if attempt > 0 {
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                writeDebugLog("[AMLL] retrying in \(delay)s (attempt \(attempt + 1)/\(Self.maxAttempts))")
                Thread.sleep(forTimeInterval: delay)
            }

            switch performGet(trackId: trackId) {
            case .success(let item):
                return item
            case .fatal(let error):
                throw error
            case .retryable(let reason, let cause):
                writeDebugLog("[AMLL] attempt \(attempt + 1)/\(Self.maxAttempts) failed: \(reason)")
                lastError = cause
            }
        }

        writeDebugLog("[AMLL] giving up after \(Self.maxAttempts) attempts — service unavailable, not \"no lyrics\"")
        throw lastError
    }

    private func performGet(trackId: String) -> FetchOutcome {
        guard var components = URLComponents(string: "\(apiUrl)/v1/lyrics/get") else {
            writeDebugLog("[AMLL] invalid API base URL: \(apiUrl)")
            return .fatal(.invalidSource)
        }
        // 用 queryItems 而不是字符串拼接：自建镜像的基址可能自带 query，
        // 直接拼会把参数塞进错误的位置。
        components.queryItems = [URLQueryItem(name: "spotifyId", value: trackId)]

        guard let url = components.url else {
            writeDebugLog("[AMLL] failed to build request URL from base: \(apiUrl)")
            return .fatal(.invalidSource)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify",
            forHTTPHeaderField: "User-Agent"
        )

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode = 0

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            if let http = response as? HTTPURLResponse { statusCode = http.statusCode }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            task.cancel()
            writeDebugLog("[AMLL] request timed out for \(trackId)")
            return .retryable(reason: "timeout", cause: .unknownError)
        }

        if let responseError {
            writeDebugLog("[AMLL] network error for \(trackId): \(responseError)")
            return .retryable(
                reason: "network \(responseError.localizedDescription)",
                cause: .unknownError
            )
        }

        guard let data = responseData else {
            writeDebugLog("[AMLL] empty response body for \(trackId)")
            return .retryable(reason: "empty body", cause: .unknownError)
        }

        let bodyPreview = String(data: data, encoding: .utf8)?.prefix(200)
            ?? "<non-utf8 \(data.count) bytes>"

        switch statusCode {
        case 200:
            break
        case 404:
            writeDebugLog("[AMLL] 404 — no lyrics for \(trackId)")
            return .fatal(.noSuchSong)
        case 400:
            // 参数校验失败（例如自建镜像不接受 spotifyId）。配置问题，重试无用。
            writeDebugLog("[AMLL] 400 Bad Request for \(trackId): \(bodyPreview)")
            return .fatal(.invalidSource)
        case 429:
            writeDebugLog("[AMLL] 429 rate limited")
            return .retryable(reason: "429 rate limited", cause: .unknownError)
        case 502, 503, 504:
            writeDebugLog("[AMLL] \(statusCode) backend unstable: \(bodyPreview)")
            return .retryable(reason: "\(statusCode) backend unstable", cause: .unknownError)
        default:
            if (500...599).contains(statusCode) {
                writeDebugLog("[AMLL] \(statusCode) server error: \(bodyPreview)")
                return .retryable(reason: "\(statusCode) server error", cause: .unknownError)
            }
            writeDebugLog("[AMLL] unexpected status \(statusCode): \(bodyPreview)")
            return .fatal(.unknownError)
        }

        // 成功响应结构：{"status":200,"data":{...}}
        struct GetEnvelope: Decodable {
            var status: Int?
            var data: AmllSongItem?
        }

        let envelope: GetEnvelope
        do {
            envelope = try JSONDecoder().decode(GetEnvelope.self, from: data)
        } catch {
            writeDebugLog("[AMLL] failed to decode envelope: \(error); body: \(bodyPreview)")
            return .fatal(.decodingError)
        }

        guard let item = envelope.data else {
            writeDebugLog("[AMLL] 200 but no data field: \(bodyPreview)")
            return .fatal(.decodingError)
        }

        writeDebugLog(
            "[AMLL] matched id=\(item.id.map(String.init) ?? "?") file=\(item.filename ?? "?") author=\(item.primaryAuthorUsername ?? "?")"
        )
        return .success(item)
    }

    // MARK: - 日志

    private func logSummary(item: AmllSongItem, parsed: AmllTtmlResult, dto: LyricsDto) {
        let wordLines = dto.lines.filter { ($0.words?.count ?? 0) >= 2 }.count
        let translationCount = dto.translation?.lines.filter { !$0.isEmpty }.count ?? 0
        let romanizationState = switch dto.romanization {
        case .romanized: "official"        // repository 层已用 x-roman 替换主行文本
        case .canBeRomanized: "deferred"   // 交给显示层的本地罗马化链路
        case .original: "none"
        }
        writeDebugLog(
            "[AMLL] \(dto.lines.count) line(s), \(wordLines) word-level, "
                + "\(translationCount) translated, romanization=\(romanizationState), "
                + "lang=\(dto.languageCode ?? "?")"
        )
        if parsed.hasRomanization, romanizationState == "deferred" {
            writeDebugLog("[AMLL] TTML carries x-roman but it was not applied (see mapper log above)")
        }
        if let declared = parsed.declaredDurationMs, let lastEnd = parsed.lastLineEndMs {
            writeDebugLog("[AMLL] declared dur \(declared)ms, last line end \(lastEnd)ms (neither is audio length)")
        }
    }
}
