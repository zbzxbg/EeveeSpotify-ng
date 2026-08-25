import Foundation
import Orion

// MARK: - Spotify Bearer token 捕获
//
// 从 Spotify 出站请求里捕获 Bearer token，供 SpicyLyrics 等歌词源复用
// （api.spicylyrics.org 需要 Spotify 自身的 token 才返回歌词）。
// URLSession 回调和歌词仓库跑在不同队列，token 必须用锁保护的存储，
// 不能直接读写无保护的 Swift 全局 String。
private final class SpotifyAccessTokenStore {
    static let shared = SpotifyAccessTokenStore()

    private let lock = NSLock()
    private var value: String?

    func set(_ token: String?) {
        lock.lock()
        value = token
        lock.unlock()
    }

    func snapshot() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func setSpotifyAccessToken(_ token: String?) {
    SpotifyAccessTokenStore.shared.set(token)
}

func spotifyAccessTokenSnapshot() -> String? {
    SpotifyAccessTokenStore.shared.snapshot()
}

// MARK: - 线程安全的拦截上下文（按 taskIdentifier 隔离）
final class InterceptionContext {
    static let shared = InterceptionContext()

    private let lock = NSLock()
    private var stateByTaskID: [Int: State] = [:]
    private var dataByTaskID: [Int: Data] = [:]
    private var customDataByTaskID: [Int: Data] = [:]
    private var pendingResponseByTaskID: [Int: HTTPURLResponse] = [:]

    enum State {
        case buffering              // 普通修改：缓冲真实数据，完成时替换
        case replacingResponse      // 歌词非200：伪造200响应，忽略真实数据/错误
    }

    func setState(_ state: State, for task: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        stateByTaskID[task.taskIdentifier] = state
    }

    func getState(for task: URLSessionDataTask) -> State? {
        lock.lock()
        defer { lock.unlock() }
        return stateByTaskID[task.taskIdentifier]
    }

    func appendData(_ data: Data, for task: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        let id = task.taskIdentifier
        if var existing = dataByTaskID[id] {
            existing.append(data)
            dataByTaskID[id] = existing
        } else {
            dataByTaskID[id] = data
        }
    }

    func getData(for task: URLSessionDataTask) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return dataByTaskID[task.taskIdentifier]
    }

    func setCustomData(_ data: Data, for task: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        customDataByTaskID[task.taskIdentifier] = data
    }

    func getCustomData(for task: URLSessionDataTask) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return customDataByTaskID[task.taskIdentifier]
    }

    func setPendingResponse(_ response: HTTPURLResponse, for task: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        pendingResponseByTaskID[task.taskIdentifier] = response
    }

    func getPendingResponse(for task: URLSessionDataTask) -> HTTPURLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return pendingResponseByTaskID[task.taskIdentifier]
    }

    func removeAll(for task: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        let id = task.taskIdentifier
        stateByTaskID.removeValue(forKey: id)
        dataByTaskID.removeValue(forKey: id)
        customDataByTaskID.removeValue(forKey: id)
        pendingResponseByTaskID.removeValue(forKey: id)
    }
}

class SPTDataLoaderServiceHook: ClassHook<NSObject>, SpotifySessionDelegate {
    static let targetName = "SPTDataLoaderService"

    // orion:new
    func shouldModify(_ url: URL) -> Bool {
        let shouldPatchPremium = BasePremiumPatchingGroup.isActive
        let shouldReplaceLyrics = BaseLyricsGroup.isActive

        return (shouldReplaceLyrics && url.isLyrics)
            || (shouldPatchPremium && (url.isCustomize || url.isPremiumPlanRow || url.isPremiumBadge || url.isPlanOverview))
    }

    // MARK: - 辅助方法：发送数据 + 完成
    private func sendDataAndComplete(
        _ data: Data,
        task: URLSessionDataTask,
        session: URLSession,
        error: Error? = nil
    ) {
        orig.URLSession(session, dataTask: task, didReceiveData: data)
        orig.URLSession(session, task: task, didCompleteWithError: error)
    }

    // MARK: - URLSessionDataDelegate

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: HTTPURLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let url = task.currentRequest?.url else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        if url.isLyrics && NgzhwmSettingsViewModel.isLyricsFeatureDisabled {
            handler(.cancel)
            return
        }

        guard shouldModify(url) else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // 1. 歌词请求且状态码非200：伪造200响应
        if url.isLyrics && response.statusCode != 200 {
            writeDebugLog("[DL] Lyrics request non-200 (\(response.statusCode)) — replacing")
            do {
                let customData = try getLyricsDataForCurrentTrack(url.path)

                // 构造200响应，尽量保留原有header和httpVersion
                let headerFields = response.allHeaderFields as? [String: String] ?? [:]
                let okResponse = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: headerFields
                ) ?? HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!

                // 标记任务为“替换响应”，并缓存自定义数据
                InterceptionContext.shared.setState(.replacingResponse, for: task)
                InterceptionContext.shared.setCustomData(customData, for: task)

                // 允许系统继续接收数据（真实错误数据会被我们在 didReceiveData 中忽略）
                orig.URLSession(session, dataTask: task, didReceiveResponse: okResponse, completionHandler: handler)
                return
            } catch {
                // 自定义歌词失败时透传原始响应，让官方错误流程处理，不再伪造空歌词。
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
                return
            }
        }

        // 2. 其他需要修改的请求：仅当原始响应成功（2xx）时才拦截
        guard (200..<300).contains(response.statusCode) else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // 标记为缓冲模式，后续数据将被缓冲，完成时替换。
        // 歌词响应暂不立即交给 Spotify；否则后续 Genius noSuchSong
        // 即使抛错，Spotify 已经收到 2xx 响应，也只会显示空歌词。
        InterceptionContext.shared.setState(.buffering, for: task)
        if url.isLyrics {
            writeDebugLog("[DL] Buffering lyrics response (status \(response.statusCode))")
            InterceptionContext.shared.setPendingResponse(response, for: task)
            // 允许网络继续传输；响应本身会在 didCompleteWithError 中
            // 根据自定义歌词结果再交给 Spotify 的原始处理器。
            handler(.allow)
        } else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard let url = task.currentRequest?.url else {
            orig.URLSession(session, dataTask: task, didReceiveData: data)
            return
        }

        guard let state = InterceptionContext.shared.getState(for: task) else {
            orig.URLSession(session, dataTask: task, didReceiveData: data)
            return
        }

        switch state {
        case .replacingResponse:
            // 忽略伪造响应后的真实错误数据
            break

        case .buffering:
            // 缓冲数据，暂不转发给上层
            InterceptionContext.shared.appendData(data, for: task)
            break
        }
    }

    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        // 任何携带 Bearer token 的 Spotify 请求都顺手记录最新 token，
        // 供 SpicyLyrics 歌词请求复用（先于一切 guard，保证所有任务都过一遍）。
        if let request = task.currentRequest,
           let headers = request.allHTTPHeaderFields,
           let auth = headers["Authorization"] ?? headers["authorization"],
           auth.hasPrefix("Bearer ") {
            setSpotifyAccessToken(String(auth.dropFirst(7)))
            writeDebugLog("[TokenCapture] Bearer token from \(task.currentRequest?.url?.absoluteString ?? "?")")
        }

        guard let url = task.currentRequest?.url else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        guard let state = InterceptionContext.shared.getState(for: task) else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        // 确保无论如何都清理任务状态与数据
        defer {
            InterceptionContext.shared.removeAll(for: task)
        }

        switch state {
        case .replacingResponse:
            // 使用缓存的自定义歌词数据；缓存丢失时将错误交给官方流程。
            if let cached = InterceptionContext.shared.getCustomData(for: task) {
                writeDebugLog("[DL] Custom lyrics accepted (non-200 fallback)")
                sendDataAndComplete(cached, task: task, session: session, error: nil)
            } else {
                do {
                    let data = try getLyricsDataForCurrentTrack(url.path)
                    sendDataAndComplete(data, task: task, session: session, error: nil)
                } catch {
                    orig.URLSession(session, task: task, didCompleteWithError: error)
                }
            }

        case .buffering:
            let pendingResponse = InterceptionContext.shared.getPendingResponse(for: task)

            guard error == nil else {
                // 原始请求失败时，先恢复被暂存的响应，再透传网络错误。
                if let pendingResponse {
                    orig.URLSession(
                        session,
                        dataTask: task,
                        didReceiveResponse: pendingResponse,
                        completionHandler: { _ in }
                    )
                }
                orig.URLSession(session, task: task, didCompleteWithError: error)
                return
            }

            guard let buffer = InterceptionContext.shared.getData(for: task) else {
                // 没有缓冲到数据（极端情况），恢复原始响应并完成请求。
                if let pendingResponse {
                    orig.URLSession(
                        session,
                        dataTask: task,
                        didReceiveResponse: pendingResponse,
                        completionHandler: { _ in }
                    )
                }
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }

            do {
                if url.isLyrics {
                    let customData = try getLyricsDataForCurrentTrack(
                        url.path,
                        originalLyrics: try? Lyrics(serializedBytes: buffer)
                    )
                    writeDebugLog("[DL] Custom lyrics accepted")
                    if let pendingResponse {
                        orig.URLSession(
                            session,
                            dataTask: task,
                            didReceiveResponse: pendingResponse,
                            completionHandler: { _ in }
                        )
                    }
                    sendDataAndComplete(customData, task: task, session: session, error: nil)
                } else if url.isPremiumPlanRow {
                    writeDebugLog("[DL] Patching premium plan row")
                    let customData = try getPremiumPlanRowData(
                        originalPremiumPlanRow: try PremiumPlanRow(serializedBytes: buffer)
                    )
                    sendDataAndComplete(customData, task: task, session: session, error: nil)
                } else if url.isPremiumBadge {
                    writeDebugLog("[DL] Patching premium badge")
                    let customData = try getPremiumPlanBadge()
                    sendDataAndComplete(customData, task: task, session: session, error: nil)
                } else if url.isCustomize {
                    writeDebugLog("[DL] Patching customize response")
                    var customizeMessage = try CustomizeMessage(serializedBytes: buffer)
                    modifyRemoteConfiguration(&customizeMessage.response)
                    let customData = try customizeMessage.serializedData()
                    sendDataAndComplete(customData, task: task, session: session, error: nil)
                } else if url.isPlanOverview {
                    writeDebugLog("[DL] Patching plan overview")
                    let customData = try getPlanOverviewData()
                    sendDataAndComplete(customData, task: task, session: session, error: nil)
                } else {
                    // 理论上不会发生，回退原始数据
                    sendDataAndComplete(buffer, task: task, session: session, error: nil)
                }
            } catch {
                if url.isLyrics, let pendingResponse {
                    // 自定义歌词失败时返回 HTTP 错误响应。此时 Spotify 尚未收到
                    // 原始 2xx 响应，才能进入原有的黑色“无歌词”错误界面。
                    let errorResponse = HTTPURLResponse(
                        url: pendingResponse.url ?? url,
                        statusCode: 500,
                        httpVersion: "HTTP/1.1",
                        headerFields: pendingResponse.allHeaderFields as? [String: String]
                    ) ?? pendingResponse
                    orig.URLSession(
                        session,
                        dataTask: task,
                        didReceiveResponse: errorResponse,
                        completionHandler: { _ in }
                    )
                    orig.URLSession(session, task: task, didCompleteWithError: nil)
                } else if url.isLyrics {
                    orig.URLSession(session, task: task, didCompleteWithError: error)
                } else {
                    sendDataAndComplete(buffer, task: task, session: session, error: nil)
                }
            }
        }
    }
}