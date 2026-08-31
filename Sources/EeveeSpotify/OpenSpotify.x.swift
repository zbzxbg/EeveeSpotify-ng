import Orion
import UIKit

class UIOpenURLContextHook: ClassHook<UIOpenURLContext> {
    func URL() -> URL {
        let url = orig.URL()

        if url.isOpenSpotifySafariExtension {
            writeDebugLog("[URI] Rewrote openSpotify Safari extension URL")
            return Foundation.URL(string: "https:/\(url.path)")!
        }

        return url
    }
}
