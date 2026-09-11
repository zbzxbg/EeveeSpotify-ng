import UIKit
import Combine

struct AnonymousTokenHelper {
    private static let apiUrl = "https://apic.musixmatch.com"
    
    static func requestAnonymousMusixmatchToken() -> AnyPublisher<String, Error> {
        let url = URL(string: "\(apiUrl)/ws/1.1/token.get?app_id=\(UIDevice.current.musixmatchAppId)")!
        writeDebugLog("[Musixmatch] Requesting anonymous token: \(url.absoluteString)")

        // 和 MusixmatchLyricsRepository 一样补上 Safari 形态的 UA，否则同一 host 同样会被 nginx 挡住。
        var request = URLRequest(url: url)
        request.setValue(UIDevice.current.safariUserAgent, forHTTPHeaderField: "User-Agent")

        return URLSession.shared.dataTaskPublisher(for: request)
            .map(\.data)
            .tryMap { data in
                guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let message = json["message"] as? [String: Any],
                      let body = message["body"] as? [String: Any],
                      let userToken = body["user_token"] as? String
                else {
                    writeErrorLog("[Musixmatch] Anonymous token response invalid")
                    throw AnonymousTokenError.invalidResponse
                }
                
                return userToken
            }
            .handleEvents(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    writeErrorLog("[Musixmatch] Anonymous token request failed: \(error)")
                } else {
                    writeDebugLog("[Musixmatch] Anonymous token acquired")
                }
            })
            .eraseToAnyPublisher()
    }
}
