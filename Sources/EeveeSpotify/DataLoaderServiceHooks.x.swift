import Foundation
import Orion

// MARK: - 线程安全的拦截上下文（按 taskIdentifier 隔离）
final class InterceptionContext {
    static let shared = InterceptionContext()

    private let lock = NSLock()
    private var stateByTaskID: [Int: State] = [:]
    private var dataByTaskID: [Int: Data] = [:]
    private var customDataByTaskID: [Int: Data] = [:]

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

    func removeAll(for task: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        let id = task.taskIdentifier
        stateByTaskID.removeValue(forKey: id)
        dataByTaskID.removeValue(forKey: id)
        customDataByTaskID.removeValue(forKey: id)
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

        guard shouldModify(url) else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // 1. 歌词请求且状态码非200：伪造200响应
        if url.isLyrics && response.statusCode != 200 {
            do {
                let customData = try getLyricsDataForCurrentTrack(url.path)

                // 构造200响应，尽量保留原有header和httpVersion
                let headerFields = response.allHeaderFields as? [String: String] ?? [:]
                let okResponse = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: headerFields
                ) ?? HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!

                // 标记任务为“替换响应”，并缓存自定义数据
                InterceptionContext.shared.setState(.replacingResponse, for: task)
                InterceptionContext.shared.setCustomData(customData, for: task)

                // 允许系统继续接收数据（真实错误数据会被我们在 didReceiveData 中忽略）
                orig.URLSession(session, dataTask: task, didReceiveResponse: okResponse, completionHandler: handler)
                return
            } catch {
                // 无法生成自定义歌词，透传原始错误响应
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
                return
            }
        }

        // 2. 其他需要修改的请求：仅当原始响应成功（2xx）时才拦截
        guard (200..<300).contains(response.statusCode) else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // 标记为缓冲模式，后续数据将被缓冲，完成时替换
        InterceptionContext.shared.setState(.buffering, for: task)
        orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
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
            // 使用缓存的自定义歌词数据，若缓存丢失则重新生成或回退为空数据
            let data: Data
            if let cached = InterceptionContext.shared.getCustomData(for: task) {
                data = cached
            } else {
                do {
                    data = try getLyricsDataForCurrentTrack(url.path)
                } catch {
                    data = Data()
                }
            }
            sendDataAndComplete(data, task: task, session: session, error: nil)

        case .buffering:
            guard error == nil else {
                // 原始请求失败（理论上不会发生，因为只有2xx才进入此状态），直接透传错误
                orig.URLSession(session, task: task, didCompleteWithError: error)
                return
            }

            guard let buffer = InterceptionContext.shared.getData(for: task) else {
                // 没有缓冲到数据（极端情况），透传成功完成
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }

            do {
                if url.isLyrics {
                    let customData = try getLyricsDataForCurrentTrack(
                        url.path,
                        originalLyrics: try? Lyrics(serializedBytes: buffer)
                    )
                    sendDataAndComplete(customData, task: task, session: session, error: nil)
                } else if url.isPremiumPlanRow {
                    let customData = try getPremiumPlanRowData(
                        originalPremiumPlanRow: try PremiumPlanRow(serializedBytes: buffer)
                    )
                    sendDataAndComplete(customData, task: task, session: session, error: nil)
                } else if url.isPremiumBadge {
                    let customData = try getPremiumPlanBadge()
                    sendDataAndComplete(customData, task: task, session: session, error: nil)
                } else if url.isCustomize {
                    var customizeMessage = try CustomizeMessage(serializedBytes: buffer)
                    modifyRemoteConfiguration(&customizeMessage.response)
                    let customData = try customizeMessage.serializedData()
                    sendDataAndComplete(customData, task: task, session: session, error: nil)
                } else if url.isPlanOverview {
                    let customData = try getPlanOverviewData()
                    sendDataAndComplete(customData, task: task, session: session, error: nil)
                } else {
                    // 理论上不会发生，回退原始数据
                    sendDataAndComplete(buffer, task: task, session: session, error: nil)
                }
            } catch {
                // 解析/生成失败，回退到原始数据
                sendDataAndComplete(buffer, task: task, session: session, error: nil)
            }
        }
    }
}