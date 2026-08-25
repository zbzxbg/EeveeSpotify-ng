import Foundation
import CommonCrypto

// MARK: - NeteaseLyricsRepository
//
// 网易云音乐歌词源（直连 weapi）。
//
// ── 为什么直连可行 ──────────────────────────────────────────────────────────
// music.163.com 的 weapi 接口要求每个请求体携带 params / encSecKey 两个
// 加密字段，但整套加密是「无状态」的：AES 密钥、IV 与 RSA 公钥都是全网
// 写死的常量，不涉及任何用户身份，因此无需像 Musixmatch 那样要求用户
// 提供 token。会话层只需一个匿名 cookie（MUS_U，由 register/anonimous
// 接口自动下发，有效期约一年），客户端自己申请并持久化即可。
//
// ── weapi 加密流程（与 NeteaseCloudMusicApi/util/crypto.js 一致）───────
// 1. 随机 16 字符 secKey；
// 2. params = AES-CBC(明文, key="0CoJUm6Qyw8W8jud", iv="0102030405060708")，
//    再对结果用 key=secKey 加密一次，两次结果均做 base64；
// 3. encSecKey = hex( rawRSA( reverse(secKey), e=65537, 固定 1024 位模数 ) )，
//    左补零到 256 个 hex 字符。这里的 RSA 是无填充的原始模幂（m^e mod n），
//    与 JS 端 BigInt.powMod 等价。
//
// ── 失败兜底 ───────────────────────────────────────────────────────────────
// 本仓库的请求失败/查无此歌统一抛 LyricsError，由 CustomLyrics.x.swift 的
// 既有回退逻辑（geniusFallback 等）接管；本文件不参与多级回退编排。

class NeteaseLyricsRepository: LyricsRepository {

    static let shared = NeteaseLyricsRepository()

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    private let session: URLSession

    private class CachedLyrics {
        let dto: LyricsDto

        init(dto: LyricsDto) {
            self.dto = dto
        }
    }

    private let lyricsCache = NSCache<NSString, CachedLyrics>()

    // MARK: - 常量

    private static let weapiBaseUrl = "https://music.163.com"
    private static let aesFirstKey = "0CoJUm6Qyw8W8jud"
    private static let aesIv = "0102030405060708"

    /// weapi 固定 RSA 公钥模数（1024 位，hex，无前导 00）。
    private static let rsaModulusHex =
        "e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725" +
        "152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e031" +
        "2ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b4" +
        "24d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a2" +
        "2b8e7"

    private static let rsaExponent = 65537

    /// 匿名 cookie 持久化 key（MUS_U 有效期约一年，跨启动复用）。
    private static let anonymousCookieKey = "ngzhwm_neteaseAnonymousCookie"

    /// 匿名注册并发保护：首次使用可能有多个歌词请求同时触发注册。
    private static let cookieLock = NSLock()

    private var anonymousCookie: String {
        get { UserDefaults.standard.string(forKey: Self.anonymousCookieKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.anonymousCookieKey) }
    }

    /// 从匿名 cookie 里提取 __csrf，作为 weapi 请求的 csrf_token。
    private var csrfToken: String {
        let cookie = anonymousCookie
        guard let match = cookie.firstMatch("__csrf=([^;]+)"),
              let tokenRange = Range(match.range(at: 1), in: cookie) else {
            return ""
        }
        return String(cookie[tokenRange])
    }

    // MARK: - weapi 加密

    /// AES-128-CBC + PKCS7（密钥为 16 字节 UTF-8 字符串，IV 固定）。
    private func aesCbcEncrypt(_ data: Data, key: String) -> Data? {
        guard let keyData = key.data(using: .utf8),
              let ivData = Self.aesIv.data(using: .utf8) else {
            return nil
        }

        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var bytesEncrypted = 0

        let status: CCCryptorStatus = buffer.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                keyData.withUnsafeBytes { keyBytes in
                    ivData.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyData.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress, data.count,
                            outBytes.baseAddress, bufferSize,
                            &bytesEncrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return buffer.prefix(bytesEncrypted)
    }

    /// 生成 (params, encSecKey)，与网易前端 weapi 加密等价。
    private func weapiEncrypt(_ text: String) throws -> (params: String, encSecKey: String) {
        let secKeyCharacters =
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let secKey = String((0..<16).compactMap { _ in secKeyCharacters.randomElement() })

        guard let firstPass = aesCbcEncrypt(Data(text.utf8), key: Self.aesFirstKey),
              let secondPass = aesCbcEncrypt(firstPass, key: secKey) else {
            throw LyricsError.decodingError
        }
        let params = secondPass.base64EncodedString()

        // encSecKey = hex(reverse(secKey) 作为大整数 ^ 65537 mod modulus)，左补零到 256 hex。
        var reversedKeyHex = ""
        for byte in String(secKey.reversed()).utf8 {
            reversedKeyHex += String(format: "%02x", byte)
        }

        guard let message = NeteaseBigUInt(hex: reversedKeyHex),
              let modulus = NeteaseBigUInt(hex: Self.rsaModulusHex) else {
            throw LyricsError.decodingError
        }

        let cipher = NeteaseBigUInt.powMod(
            base: message,
            exponent: NeteaseBigUInt(limbs: [UInt64(Self.rsaExponent)]),
            modulus: modulus
        )

        return (params, cipher.hexString(paddedTo: 256))
    }

    // MARK: - 网络

    private func performWeapi(_ path: String, params: [String: Any]) throws -> Data {
        var weapiParams = params
        weapiParams["csrf_token"] = csrfToken

        let bodyText: String
        do {
            let bodyData = try JSONSerialization.data(withJSONObject: weapiParams)
            guard let text = String(data: bodyData, encoding: .utf8) else {
                throw LyricsError.decodingError
            }
            bodyText = text
        } catch {
            throw LyricsError.decodingError
        }

        let (encryptedParams, encSecKey) = try weapiEncrypt(bodyText)

        let csrf = csrfToken
        guard let url = URL(string: "\(Self.weapiBaseUrl)\(path)?csrf_token=\(csrf)") else {
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        var cookie = "os=pc"
        let savedCookie = anonymousCookie
        if !savedCookie.isEmpty {
            cookie += "; " + savedCookie
        }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "params", value: encryptedParams),
            URLQueryItem(name: "encSecKey", value: encSecKey),
        ]
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode = 0
        var responseCookie: String?

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                if let headers = http.allHeaderFields as? [String: String] {
                    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
                    if !cookies.isEmpty {
                        responseCookie = cookies
                            .map { "\($0.name)=\($0.value)" }
                            .joined(separator: "; ")
                    }
                }
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            throw LyricsError.unknownError
        }

        if let error = responseError {
            throw error
        }

        guard statusCode == 200 else {
            throw LyricsError.unknownError
        }

        guard let data = responseData else {
            throw LyricsError.decodingError
        }

        if let cookieValue = responseCookie, !cookieValue.isEmpty {
            anonymousCookie = cookieValue
        }

        return data
    }

    /// 确保已持有匿名 cookie；没有则调 register/anonimous 自动申请。
    /// 接口下发的 MUS_U 有效期约一年，持久化后跨启动复用。
    private func ensureAnonymousCookie() throws {
        Self.cookieLock.lock()
        defer { Self.cookieLock.unlock() }

        if !anonymousCookie.isEmpty { return }
        _ = try performWeapi("/weapi/register/anonimous", params: [:])
    }

    // MARK: - 接口

    private func searchSongs(keyword: String) throws -> [[String: Any]] {
        let data = try performWeapi("/weapi/cloudsearch/get/web", params: [
            "s": keyword,
            "type": 1,
            "limit": 30,
            "offset": 0,
            "total": true,
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            throw LyricsError.decodingError
        }

        return songs
    }

    private func fetchLyricsRaw(songId: Int) throws -> (lrc: String?, tlyric: String?) {
        let data = try performWeapi("/weapi/song/lyric", params: [
            "id": songId,
            "lv": -1,
            "tv": -1,
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.decodingError
        }

        guard (json["code"] as? Int ?? 200) == 200 else {
            throw LyricsError.noSuchSong
        }

        let lrc = (json["lrc"] as? [String: Any])?["lyric"] as? String
        let tlyric = (json["tlyric"] as? [String: Any])?["lyric"] as? String
        return (lrc, tlyric)
    }

    private func songId(from song: [String: Any]) -> Int? {
        if let value = song["id"] as? Int { return value }
        if let value = song["id"] as? Int64 { return Int(value) }
        return nil
    }

    // MARK: - LRC 解析

    /// 过滤网易 LRC 里「作词 : XXX」这类歌曲制作信息行。
    private static let creditLinePattern =
        "^\\s*(作词|作曲|编曲|制作人|制作助理|混音|混音师|母带|母带工程师|录音|录音师|" +
        "监制|和声|和音|吉他|贝斯|鼓|键盘|钢琴|小提琴|大提琴|弦乐|制作|出品|发行|" +
        "配唱|统筹|企划|推广|文案|摄影|封面|导演|经纪人|" +
        "Program|Programming|Vocal|Lyrics|Composer|Arranger|Producer|" +
        "Recorded|Mixed|Mastered)\\s*[:：]"

    private func isCreditLine(_ content: String) -> Bool {
        content ~= Self.creditLinePattern
    }

    /// 把 LRC 文本解析成 (offsetMs, content)，丢弃非时间戳行与制作信息行。
    private func parseLrc(_ text: String) -> [(offsetMs: Int, content: String)] {
        var parsed: [(offsetMs: Int, content: String)] = []

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = line.firstMatch(
                "\\[(?<minute>\\d*):(?<seconds>\\d+\\.\\d+|\\d+)\\] ?(?<content>.*)"
            ) else {
                continue
            }

            guard let minuteRange = Range(match.range(withName: "minute"), in: line),
                  let secondsRange = Range(match.range(withName: "seconds"), in: line),
                  let contentRange = Range(match.range(withName: "content"), in: line),
                  let minute = Int(line[minuteRange]),
                  let seconds = Float(line[secondsRange]) else {
                continue
            }

            let content = String(line[contentRange])
            guard !isCreditLine(content) else { continue }

            parsed.append((minute * 60 * 1000 + Int(seconds * 1000), content))
        }

        return parsed
    }

    // MARK: - 翻译对齐

    /// tlyric 与原 lrc 按时间戳对齐；没有对应翻译的行填空串，
    /// 保证翻译行数与主歌词行数一致（Spotify 按行展示翻译层）。
    private func buildTranslation(
        _ tlyric: String,
        originalLines: [LyricsLineDto]
    ) -> LyricsTranslationDto? {
        let parsed = parseLrc(tlyric)
        guard !parsed.isEmpty else { return nil }

        var translationByOffset: [Int: String] = [:]
        for entry in parsed {
            if translationByOffset[entry.offsetMs] == nil, !entry.content.isEmpty {
                translationByOffset[entry.offsetMs] = entry.content
            }
        }

        var translatedLines: [String] = []
        var matchedCount = 0

        for line in originalLines {
            guard let offset = line.offsetMs, let translated = translationByOffset[offset] else {
                translatedLines.append("")
                continue
            }
            translatedLines.append(translated)
            matchedCount += 1
        }

        guard matchedCount > 0 else { return nil }

        let languageCode = translatedLines.romanizationLanguageCode ?? "zh"
        return LyricsTranslationDto(languageCode: languageCode, lines: translatedLines)
    }

    // MARK: - 候选匹配

    private func normalized(_ text: String) -> String {
        text
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
            .replacingOccurrences(
                of: "[^\\p{L}\\p{N}]+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func candidateArtistNames(_ song: [String: Any]) -> String {
        guard let artists = song["ar"] as? [[String: Any]] else { return "" }
        return artists.compactMap { $0["name"] as? String }.joined(separator: " ")
    }

    private func matchScore(
        candidate: [String: Any],
        query: LyricsSearchQuery,
        strippedTitle: String
    ) -> Int {
        let resultTitle = normalized(candidate["name"] as? String ?? "")
        let fullTitle = normalized(query.title)
        let cleanTitle = normalized(strippedTitle)
        let resultArtist = normalized(candidateArtistNames(candidate))
        let queryArtist = normalized(query.primaryArtist)

        var score = 0

        if !fullTitle.isEmpty, resultTitle == fullTitle {
            score += 100
        } else if !cleanTitle.isEmpty, resultTitle == cleanTitle {
            score += 90
        } else if (!fullTitle.isEmpty && (resultTitle.contains(fullTitle) || fullTitle.contains(resultTitle)))
            || (!cleanTitle.isEmpty && (resultTitle.contains(cleanTitle) || cleanTitle.contains(resultTitle))) {
            score += 70
        }

        if !queryArtist.isEmpty {
            if resultArtist == queryArtist {
                score += 60
            } else if resultArtist.contains(queryArtist) || queryArtist.contains(resultArtist) {
                score += 40
            } else {
                let tokens = queryArtist.split(separator: " ")
                if tokens.contains(where: { resultArtist.contains(String($0)) }) {
                    score += 15
                } else {
                    score -= 80
                }
            }
        }

        return score
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        writeDebugLog("[NetEase] Fetching lyrics for \"\(query.title)\" - \(query.primaryArtist)")
        let cacheKey = String(query.hashValue)
        if let cached = lyricsCache.object(forKey: cacheKey as NSString) {
            writeDebugLog("[NetEase] Cache hit")
            return cached.dto
        }

        try ensureAnonymousCookie()

        let strippedTitle = query.title.strippedTrackTitle
        let keywords = [
            "\(query.title) \(query.primaryArtist)",
            "\(strippedTitle) \(query.primaryArtist)",
            query.title,
            strippedTitle,
        ]

        var songs: [[String: Any]] = []
        var lastSearchError: Error?

        for keyword in keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                songs = try searchSongs(keyword: trimmed)
            } catch {
                lastSearchError = error
                continue
            }
            if !songs.isEmpty { break }
        }

        if songs.isEmpty {
            if let error = lastSearchError {
                writeDebugLog("[NetEase] Search error: \(error)")
                throw error
            }
            writeDebugLog("[NetEase] No search results")
            throw LyricsError.noSuchSong
        }
        writeDebugLog("[NetEase] Search returned \(songs.count) result(s)")

        let ranked = songs
            .map { (song: $0, score: matchScore(candidate: $0, query: query, strippedTitle: strippedTitle)) }
            .sorted { $0.score > $1.score }

        for entry in ranked.prefix(8) {
            guard let songId = songId(from: entry.song) else { continue }

            let raw: (lrc: String?, tlyric: String?)
            do {
                raw = try fetchLyricsRaw(songId: songId)
            } catch {
                continue
            }

            guard let lrc = raw.lrc, !lrc.isEmpty else { continue }

            let parsed = parseLrc(lrc)

            // 纯音乐：网易对无词歌曲返回空 LRC 或「纯音乐」占位。
            if parsed.isEmpty, lrc.contains("纯音乐") {
                writeDebugLog("[NetEase] Instrumental — returning empty lyrics")
                let dto = LyricsDto(lines: [], timeSynced: false, romanization: .original)
                lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey as NSString)
                return dto
            }

            guard !parsed.isEmpty else { continue }

            let lines = parsed.map {
                LyricsLineDto(content: $0.content.lyricsNoteIfEmpty, offsetMs: $0.offsetMs)
            }

            var translation: LyricsTranslationDto? = nil
            if let tlyric = raw.tlyric, !tlyric.isEmpty {
                translation = buildTranslation(tlyric, originalLines: lines)
            }

            let contents = lines.map(\.content)
            let dto = LyricsDto(
                lines: lines,
                timeSynced: true,
                romanization: contents.canBeRomanized ? .canBeRomanized : .original,
                translation: translation,
                languageCode: contents.romanizationLanguageCode
            )

            writeDebugLog("[NetEase] Synced lyrics — \(lines.count) line(s)")
            lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey as NSString)
            return dto
        }

        writeDebugLog("[NetEase] No usable lyrics")
        throw LyricsError.noSuchSong
    }
}

// MARK: - NeteaseBigUInt
//
// 仅为 weapi 的 encSecKey 服务的最小无符号大整数（小端 limbs）：
// 模数是固定 1024 位、指数 65537，因此只需 乘法 / 减法 / 比较 /
// 二进制长除法取模 / 平方-乘模幂。加密对象只有 16 字节，远小于模数，
// 与网易前端 BigInt.powMod 的 raw RSA（无填充）完全等价。

private struct NeteaseBigUInt {

    var limbs: [UInt64] // little-endian，恒无前导零 limb

    static let zero = NeteaseBigUInt(limbs: [0])

    init(limbs: [UInt64]) {
        var trimmed = limbs
        while trimmed.count > 1, trimmed.last == 0 {
            trimmed.removeLast()
        }
        self.limbs = trimmed
    }

    init?(hex: String) {
        var limbs: [UInt64] = [0]
        for character in hex {
            guard let digit = character.hexDigitValue else { return nil }
            // limbs = limbs << 4 | digit
            var carry = UInt64(digit)
            for i in 0..<limbs.count {
                let shifted = limbs[i] << 4
                let sum = shifted &+ carry
                carry = (limbs[i] >> 60) &+ (sum < shifted ? 1 : 0)
                limbs[i] = sum
            }
            if carry != 0 {
                limbs.append(carry)
            }
        }
        self.init(limbs: limbs)
    }

    var isZero: Bool {
        limbs.allSatisfy { $0 == 0 }
    }

    var bitWidth: Int {
        guard let top = limbs.lastIndex(where: { $0 != 0 }) else { return 0 }
        return top * 64 + (64 - limbs[top].leadingZeroBitCount)
    }

    func bit(at index: Int) -> UInt64 {
        let word = index / 64
        guard word < limbs.count else { return 0 }
        return (limbs[word] >> UInt64(index % 64)) & 1
    }

    func shiftedLeftOneBit(insertingBit bit: UInt64) -> NeteaseBigUInt {
        guard !limbs.isEmpty else { return NeteaseBigUInt(limbs: [bit & 1]) }
        var out = [UInt64](repeating: 0, count: limbs.count + 1)
        var carry = bit & 1
        for i in 0..<limbs.count {
            out[i] = (limbs[i] << 1) | carry
            carry = limbs[i] >> 63
        }
        out[limbs.count] = carry
        return NeteaseBigUInt(limbs: out)
    }

    func shiftedRightOneBit() -> NeteaseBigUInt {
        var out = [UInt64](repeating: 0, count: limbs.count)
        var carry: UInt64 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            let nextCarry = limbs[i] & 1
            out[i] = (limbs[i] >> 1) | (carry << 63)
            carry = nextCarry
        }
        return NeteaseBigUInt(limbs: out)
    }

    func hexString(paddedTo digits: Int) -> String {
        var result = ""
        var started = false
        for limb in limbs.reversed() {
            let hex = String(limb, radix: 16)
            if !started {
                if limb != 0 {
                    result += hex
                    started = true
                }
            } else {
                result += String(repeating: "0", count: 16 - hex.count) + hex
            }
        }
        if result.isEmpty { result = "0" }
        while result.count < digits {
            result = "0" + result
        }
        return result
    }

    static func < (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        var i = lhs.limbs.count - 1
        while i >= 0 {
            if lhs.limbs[i] != rhs.limbs[i] {
                return lhs.limbs[i] < rhs.limbs[i]
            }
            i -= 1
        }
        return false
    }

    /// 假定 lhs >= rhs。
    static func - (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> NeteaseBigUInt {
        var out = [UInt64](repeating: 0, count: lhs.limbs.count)
        var borrow: UInt64 = 0
        for i in 0..<lhs.limbs.count {
            let r = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (d1, b1) = lhs.limbs[i].subtractingReportingOverflow(r)
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (b1 ? 1 : 0) &+ (b2 ? 1 : 0)
        }
        return NeteaseBigUInt(limbs: out)
    }

    static func * (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> NeteaseBigUInt {
        if lhs.isZero || rhs.isZero { return .zero }

        let m = lhs.limbs.count
        let n = rhs.limbs.count
        var result = [UInt64](repeating: 0, count: m + n)

        for i in 0..<m {
            let a = lhs.limbs[i]
            if a == 0 { continue }

            var carry: UInt64 = 0
            // carry 溢出 2^64 的部分（0 或 1），作为下一轮的额外进位。
            var carryHigh: UInt64 = 0

            for j in 0..<n {
                let (hi, lo) = a.multipliedFullWidth(by: rhs.limbs[j])
                let idx = i + j

                let t1 = result[idx] &+ lo
                let c1: UInt64 = t1 < result[idx] ? 1 : 0
                let t2 = t1 &+ carry
                let c2: UInt64 = t2 < t1 ? 1 : 0
                result[idx] = t2

                let (h1, o1) = hi.addingReportingOverflow(c1)
                let (h2, o2) = h1.addingReportingOverflow(c2)
                let (h3, o3) = h2.addingReportingOverflow(carryHigh)
                carry = h3
                carryHigh = (o1 || o2 || o3) ? 1 : 0
            }

            var idx = i + n
            while carry != 0 || carryHigh != 0 {
                if idx >= result.count { result.append(0) }
                let t1 = result[idx] &+ carry
                let c1: UInt64 = t1 < result[idx] ? 1 : 0
                result[idx] = t1
                let (h, o) = c1.addingReportingOverflow(carryHigh)
                carry = h
                carryHigh = o ? 1 : 0
                idx += 1
            }
        }

        return NeteaseBigUInt(limbs: result)
    }

    static func % (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> NeteaseBigUInt {
        if rhs.isZero { return lhs }
        if lhs < rhs { return lhs }

        // 二进制长除法：1024 位被除数约 2048 位，循环次数固定且有限。
        var remainder = NeteaseBigUInt.zero
        var i = lhs.bitWidth - 1
        while i >= 0 {
            remainder = remainder.shiftedLeftOneBit(insertingBit: lhs.bit(at: i))
            if !(remainder < rhs) {
                remainder = remainder - rhs
            }
            i -= 1
        }
        return remainder
    }

    static func powMod(
        base: NeteaseBigUInt,
        exponent: NeteaseBigUInt,
        modulus: NeteaseBigUInt
    ) -> NeteaseBigUInt {
        if modulus.isZero {
            return NeteaseBigUInt(limbs: [1])
        }

        var result = NeteaseBigUInt(limbs: [1])
        var b = base % modulus
        var e = exponent

        while !e.isZero {
            if e.bit(at: 0) == 1 {
                result = (result * b) % modulus
            }
            b = (b * b) % modulus
            e = e.shiftedRightOneBit()
        }

        return result
    }
}
