import UIKit

extension UIDevice {
    var isIpad: Bool {
        self.userInterfaceIdiom == .pad
    }
    
    var musixmatchAppId: String {
        UIDevice.current.isIpad
            ? "mac-ios-ipad-v1.0"
            : "mac-ios-v2.0"
    }

    /// Musixmatch 的 nginx 会对 App 内 URLSession 发出的请求回 403（带 nginx 默认 HTML 页），
    /// 而同一 URL、同一网络用 Safari 打开能正常拿到 JSON —— 差别在客户端请求头。
    /// 这里按本机 Safari 的形态构造 UA（iOS 版本从设备取），而不是自己编一个客户端标识，
    /// 因为「浏览器客户端能通过」是实测结论。
    var safariUserAgent: String {
        let osVersion = systemVersion.replacingOccurrences(of: ".", with: "_")
        let platform = isIpad ? "iPad; CPU OS" : "iPhone; CPU iPhone OS"

        return "Mozilla/5.0 (\(platform) \(osVersion) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }
}
