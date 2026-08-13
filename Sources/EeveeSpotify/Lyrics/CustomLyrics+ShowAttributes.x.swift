import UIKit
import Orion

class LyricsOnlyViewControllerHook: ClassHook<UIViewController> {
    typealias Group = BaseLyricsGroup

    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.LyricsOnlyViewController"
        default: return "Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController"
        }
    }

    func viewDidLoad() {
        orig.viewDidLoad()
        // 已移除回退原因和罗马音标记的附加代码
        // 现在只保留原始歌词显示，无任何修改
    }
}