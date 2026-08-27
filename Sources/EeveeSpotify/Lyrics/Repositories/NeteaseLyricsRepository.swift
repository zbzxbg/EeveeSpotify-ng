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
// 提供 token。实测 2026 年当前状态下，搜索（search/get）与歌词
// （song/lyric）接口仅需 `Cookie: os=pc` 即可匿名访问；
// register/anonimous 匿名注册接口已废弃（返回「参数错误」），不再调用。
// 若响应下发会话 cookie 会自动持久化并随后续请求携带。
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

    /// 响应下发的 cookie 持久化（部分接口会返回会话 cookie，留作复用）。
    private static let anonymousCookieKey = "ngzhwm_neteaseAnonymousCookie"

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

        // 与官网前端 asrsea / darknessomi 版一致的双层 AES 链：
        // 第二轮加密的输入必须是第一轮的 base64 文本（而非密文字节）。
        // 若传密文字节，服务器解密流程对不上，返回 HTTP 200 + 空 body。
        guard let firstPass = aesCbcEncrypt(Data(text.utf8), key: Self.aesFirstKey) else {
            writeDebugLog("[NetEase] weapiEncrypt AES failure")
            throw LyricsError.decodingError
        }
        let firstPassBase64 = firstPass.base64EncodedString()
        guard let secondPass = aesCbcEncrypt(Data(firstPassBase64.utf8), key: secKey) else {
            writeDebugLog("[NetEase] weapiEncrypt AES failure")
            throw LyricsError.decodingError
        }
        let params = secondPass.base64EncodedString()

        // encSecKey = hex(reverse(secKey) 作为大整数 ^ 65537 mod modulus)，左补零到 256 hex。
        // 手动 hex 表（避免 String(format:) 变参在设备端的类型歧义）。
        let hexTable = Array("0123456789abcdef".utf8)
        var reversedKeyHex = ""
        for byte in String(secKey.reversed()).utf8 {
            reversedKeyHex.append(Character(UnicodeScalar(hexTable[Int(byte) >> 4])))
            reversedKeyHex.append(Character(UnicodeScalar(hexTable[Int(byte) & 0xF])))
        }

        guard let message = NeteaseBigUInt(hex: reversedKeyHex),
              let modulus = NeteaseBigUInt(hex: Self.rsaModulusHex) else {
            writeDebugLog("[NetEase] weapiEncrypt hex parse failure: \(reversedKeyHex)")
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
            writeDebugLog("[NetEase] Invalid URL for \(path), csrf=\(csrf)")
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

        // 手动拼 form body 并 percent-encode：不能用 URLComponents，
        // 它按 RFC 3986 不编码 query 中的 + / =，而 base64 恰好含这三个字符，
        // 会导致 + 被服务器当成空格、= 被当成键值分隔符，base64 在传输中损坏
        // （服务器解密失败 → 返回空 body）。
        let allowedQueryCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        let encodedParams = encryptedParams.addingPercentEncoding(
            withAllowedCharacters: allowedQueryCharacters
        ) ?? encryptedParams
        let encodedSecKey = encSecKey.addingPercentEncoding(
            withAllowedCharacters: allowedQueryCharacters
        ) ?? encSecKey
        let bodyString = "params=\(encodedParams)&encSecKey=\(encodedSecKey)"
        request.httpBody = bodyString.data(using: .utf8)

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
            let body = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            writeDebugLog("[NetEase] Non-200 status \(statusCode) for \(path): \(body.prefix(200))")
            throw LyricsError.unknownError
        }

        guard let data = responseData else {
            writeDebugLog("[NetEase] Empty response data for \(path)")
            throw LyricsError.decodingError
        }

        if let cookieValue = responseCookie, !cookieValue.isEmpty {
            anonymousCookie = cookieValue
        }

        return data
    }

    // MARK: - 接口

    /// 搜索走老接口 /weapi/search/get：cloudsearch/get/web 已被网易风控
    /// （固定返回 code 50000005），实测老接口带 os=pc cookie 即可匿名使用。
    private func searchSongs(keyword: String) throws -> [[String: Any]] {
        let data = try performWeapi("/weapi/search/get", params: [
            "s": keyword,
            "type": 1,
            "limit": 30,
            "offset": 0,
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[NetEase] Search response malformed for \"\(keyword)\": \(body.prefix(300))")
            throw LyricsError.decodingError
        }

        return songs
    }

    private func fetchLyricsRaw(songId: Int) throws -> (lrc: String?, tlyric: String?, romalrc: String?) {
        // os/rv 两个参数控制 romalrc（官方日语罗马音）是否下发，参考 Lyricify-Lyrics-Helper。
        let data = try performWeapi("/weapi/song/lyric", params: [
            "id": songId,
            "os": "pc",
            "lv": -1,
            "kv": -1,
            "tv": -1,
            "rv": -1,
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.decodingError
        }

        guard (json["code"] as? Int ?? 200) == 200 else {
            throw LyricsError.noSuchSong
        }

        let lrc = (json["lrc"] as? [String: Any])?["lyric"] as? String
        let tlyric = (json["tlyric"] as? [String: Any])?["lyric"] as? String
        let romalrc = (json["romalrc"] as? [String: Any])?["lyric"] as? String
        return (lrc, tlyric, romalrc)
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

    /// 「删除间奏符号 ♪」开关（与 Musixmatch 共用同一个 ngzhwm 设置项）。
    private var shouldRemoveInterludeSymbol: Bool {
        UserDefaults.standard.bool(
            forKey: NgzhwmSettingsViewModel.removeMxmInterludeSymbolKey
        )
    }

    /// 开关开启时，把含 ♪ 的间奏行清成空白（与 MxM 的 cleanedMxmLyricsText 行为一致）。
    private func cleanedInterludeSymbol(_ text: String) -> String {
        guard shouldRemoveInterludeSymbol, text.contains("♪") else { return text }
        return ""
    }

    /// 是否为 ♪ 间奏行：空行，或整行只有 ♪ 符号（含多个 ♪ / 前后空白）。
    /// 用作翻译错位修复时「哪一行算间奏」的判定。
    private func isInterludeRow(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.allSatisfy { $0 == "♪" }
    }

    /// 把 LRC 文本解析成 (offsetMs, content)，丢弃非时间戳行与制作信息行。
    /// 网易 LRC 的时间戳混用两种厘秒分隔符：[mm:ss.xx] 与 [mm:ss:xx]，
    /// 且重复段落会合并成一行多时间戳（如 [00:01.00][00:02.00]歌词），
    /// 每个时间戳都拆成独立一行，避免时间戳混进正文显示。
    private func parseLrc(_ text: String) -> [(offsetMs: Int, content: String)] {
        var parsed: [(offsetMs: Int, content: String)] = []

        let timestampPattern = "\\[(?<minute>\\d*):(?<seconds>\\d+(?:[.:]\\d+)?)\\]"
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else {
            return parsed
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsLine = line as NSString

            let matches = regex.matches(
                in: line,
                range: NSRange(location: 0, length: nsLine.length)
            )
            guard let lastMatch = matches.last else { continue }

            // 正文 = 最后一个时间戳之后的内容
            let lastRange = lastMatch.range
            let content = nsLine.substring(from: lastRange.location + lastRange.length)
                .trimmingCharacters(in: .whitespaces)
            guard !isCreditLine(content) else { continue }

            // 每个时间戳拆成独立一行（相同正文、不同 offset）
            for match in matches {
                let minuteRange = match.range(withName: "minute")
                let secondsRange = match.range(withName: "seconds")
                guard minuteRange.location != NSNotFound,
                      secondsRange.location != NSNotFound else {
                    continue
                }

                guard let minute = Int(nsLine.substring(with: minuteRange)),
                      let seconds = Float(
                          nsLine.substring(with: secondsRange)
                              .replacingOccurrences(of: ":", with: ".")
                      ) else {
                    continue
                }

                parsed.append((minute * 60 * 1000 + Int(seconds * 1000), content))
            }
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
            // 开关开启时：翻译里 ♪ 单独作为一行的，清成空白（保持行数对齐）。
            if shouldRemoveInterludeSymbol,
               translated.trimmingCharacters(in: .whitespaces) == "♪" {
                translatedLines.append("")
            } else {
                translatedLines.append(translated)
            }
            matchedCount += 1
        }

        guard matchedCount > 0 else { return nil }

        // 网易 tlyric 的时间戳偶发与主歌词错位：某行歌词的翻译可能落在
        // 上一行的 ♪ 间奏行上。逐行检查：♪ 间奏行有翻译、而下一行歌词没有
        // 翻译时，把翻译下移给下一行；下一行已有翻译则保持不变。
        // 从左到右处理，连续多行间奏会自动接力下移。
        if translatedLines.count > 1 {
            for i in 0..<(translatedLines.count - 1) where isInterludeRow(originalLines[i].content) {
                let current = translatedLines[i].trimmingCharacters(in: .whitespaces)
                let next = translatedLines[i + 1].trimmingCharacters(in: .whitespaces)
                // 纯 ♪ 占位翻译不算真翻译，不搬；下一行已有翻译则保持不变。
                guard !current.isEmpty,
                      !current.allSatisfy({ $0 == "♪" }),
                      next.isEmpty else { continue }
                translatedLines[i + 1] = translatedLines[i]
                translatedLines[i] = ""
            }
        }

        let languageCode = translatedLines.romanizationLanguageCode ?? "zh"
        return LyricsTranslationDto(languageCode: languageCode, lines: translatedLines)
    }

    // MARK: - 官方罗马音

    /// 用网易官方 romalrc（日语罗马音）按时间戳替换主歌词行。
    /// 只有对应 offset 命中时才替换，未命中的行保留原文，返回实际替换的行数。
    private func applyRomanization(
        _ romalrc: String,
        originalLines: [LyricsLineDto]
    ) -> (lines: [LyricsLineDto], matched: Int) {
        let parsed = parseLrc(romalrc)
        guard !parsed.isEmpty else { return (originalLines, 0) }

        var romanizedByOffset: [Int: String] = [:]
        for entry in parsed {
            if romanizedByOffset[entry.offsetMs] == nil, !entry.content.isEmpty {
                romanizedByOffset[entry.offsetMs] = entry.content
            }
        }

        var out: [LyricsLineDto] = []
        var matched = 0
        for line in originalLines {
            if let offset = line.offsetMs, let roma = romanizedByOffset[offset] {
                out.append(LyricsLineDto(content: roma, offsetMs: offset))
                matched += 1
            } else {
                out.append(line)
            }
        }
        return (out, matched)
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        writeDebugLog("[NetEase] Fetching lyrics for \"\(query.title)\" - \(query.primaryArtist)")
        let cacheKey = String(query.hashValue)
        if let cached = lyricsCache.object(forKey: cacheKey as NSString) {
            writeDebugLog("[NetEase] Cache hit")
            return cached.dto
        }

        let strippedTitle = query.title.strippedTrackTitle
        let keyword = "\(strippedTitle) \(query.primaryArtist)"
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let songs: [[String: Any]]
        do {
            songs = try searchSongs(keyword: keyword)
        } catch {
            writeDebugLog("[NetEase] Search error: \(error)")
            throw error
        }

        guard !songs.isEmpty else {
            writeDebugLog("[NetEase] No search results")
            throw LyricsError.noSuchSong
        }
        writeDebugLog("[NetEase] Search returned \(songs.count) result(s)")

        // 信任网易搜索相关度，直接取第一位。标题子串匹配在跨语言（罗马音 vs 汉字/假名）
        // 时对不上、英文通用标题又会撞上别的歌手同名歌，反而选错，故不再使用。
        let chosen = songs.first!
        writeDebugLog("[NetEase] Chosen: \(chosen["name"] as? String ?? "?") (id \(chosen["id"] ?? "?"))")

        // 时长闸门：Spotify 侧能拿到时长时才生效。原曲不在网易时，第一位的错歌
        // 时长通常对不上，直接抛 noSuchSong 交给 Genius，避免返回错误歌词。
        if let spotifyDurationMs = query.durationMs,
           let neteaseDurationMs = (chosen["duration"] as? NSNumber)?.intValue,
           abs(neteaseDurationMs - spotifyDurationMs) > 5000 {
            writeDebugLog("[NetEase] Duration mismatch: spotify=\(spotifyDurationMs)ms netease=\(neteaseDurationMs)ms — noSuchSong")
            throw LyricsError.noSuchSong
        }

        guard let songId = songId(from: chosen) else {
            writeDebugLog("[NetEase] Chosen result has no song id")
            throw LyricsError.noSuchSong
        }

        let raw: (lrc: String?, tlyric: String?, romalrc: String?)
        do {
            raw = try fetchLyricsRaw(songId: songId)
        } catch {
            writeDebugLog("[NetEase] Fetch lyrics error: \(error)")
            throw error
        }

        // 纯音乐：网易对无词歌曲返回「纯音乐，请欣赏」占位，按纯音乐返回占位。
        if let lrc = raw.lrc, lrc.contains("纯音乐") {
            writeDebugLog("[NetEase] Instrumental — returning empty lyrics")
            let dto = LyricsDto(lines: [], timeSynced: false, romanization: .original)
            lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey as NSString)
            return dto
        }

        // 不把上游「空歌词 → 纯音乐占位」的 bug 带过来：没有可用歌词就抛查无此歌。
        guard let lrc = raw.lrc, !lrc.isEmpty else {
            writeDebugLog("[NetEase] No usable lyrics")
            throw LyricsError.noSuchSong
        }

        let parsed = parseLrc(lrc)
        guard !parsed.isEmpty else {
            writeDebugLog("[NetEase] No usable lyrics")
            throw LyricsError.noSuchSong
        }

        var lines = parsed.map {
            LyricsLineDto(
                content: cleanedInterludeSymbol($0.content.lyricsNoteIfEmpty),
                offsetMs: $0.offsetMs
            )
        }

        // 开关开启时（仅网易云）：删除开头连续的间奏空行（原 ♪ 行），
        // 让真正的歌词顶到第一行；中间靠下的间奏行保持空白、不清除位置。
        if shouldRemoveInterludeSymbol {
            lines = Array(lines.drop(while: { $0.content.isEmpty }))
        }

        var translation: LyricsTranslationDto? = nil
        if let tlyric = raw.tlyric, !tlyric.isEmpty {
            translation = buildTranslation(tlyric, originalLines: lines)
        }

        let contents = lines.map(\.content)
        var romanization: LyricsRomanizationStatus = contents.canBeRomanized
            ? .canBeRomanized : .original
        let languageCode = contents.romanizationLanguageCode

        // 官方罗马音：日语歌、用户开启日语罗马化、且网易下发了 romalrc 时，
        // 直接用官方罗马音替换主歌词行（标记 .romanized 跳过本地转换）。
        // 否则保持原文 + .canBeRomanized，交给显示层做本地转换。
        if let romalrc = raw.romalrc, !romalrc.isEmpty,
           languageCode == "ja",
           UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization") {
            let romanized = applyRomanization(romalrc, originalLines: lines)
            if romanized.matched > 0 {
                lines = romanized.lines
                romanization = .romanized
                writeDebugLog("[NetEase] Applied official romaji (\(romanized.matched) line(s))")

                // 官方罗马音可能不全：时间戳未命中的行保留原文、或官方行内
                // 残留假名/汉字。逐行检查，仍含日文的行交给本地罗马字转换兜底；
                // 已罗马化的行保持官方译文不动（避免二次转换破坏官方分写）。
                // 本段位于「开启日语罗马化」守卫之内，开关关闭时不生效。
                var locallyConverted = 0
                lines = lines.map { line in
                    guard line.content.containsJapaneseScriptForRomajiFallback else { return line }
                    locallyConverted += 1
                    return LyricsLineDto(
                        content: line.content.toJapaneseRomaji(),
                        offsetMs: line.offsetMs
                    )
                }
                if locallyConverted > 0 {
                    writeDebugLog("[NetEase] Local romaji fallback for \(locallyConverted) line(s)")
                }
            }
        }

        let dto = LyricsDto(
            lines: lines,
            timeSynced: true,
            romanization: romanization,
            translation: translation,
            languageCode: languageCode
        )

        writeDebugLog("[NetEase] Synced lyrics — \(lines.count) line(s)")
        lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey as NSString)
        return dto
    }
}

// MARK: - Japanese Script Detection

private extension String {
    /// 是否仍含日文假名/汉字（用于判定官方罗马音是否完整、需要本地兜底）。
    var containsJapaneseScriptForRomajiFallback: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // 平假名 + 片假名
                 0x31F0...0x31FF, // 片假名拼音扩展
                 0xFF66...0xFF9D, // 半角片假名
                 0x3400...0x4DBF, // CJK 扩展 A
                 0x4E00...0x9FFF, // CJK 统一表意文字
                 0xF900...0xFAFF: // CJK 兼容表意文字
                return true
            default:
                return false
            }
        }
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
