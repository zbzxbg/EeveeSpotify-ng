import SwiftUI
import UIKit 

class EeveeSettingsViewController: SPTPageViewController {
    let frame: CGRect
    let settingsView: AnyView
    
    init(_ frame: CGRect, settingsView: AnyView, navigationTitle: String) {
        self.frame = frame
        self.settingsView = settingsView
        super.init(nibName: nil, bundle: nil)
        
        title = navigationTitle
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Hosting view 必须钉在本控制器可见区域内滚动。
        // 曾尝试用 NSLayoutConstraint 把 hosting view 四边钉到 self.view，
        // 但在 SPTPageViewController（Spotify 私有控制器）的某些版本/iOS 上
        // 约束无法正确收敛，List 滚动区仍按超大的内容高度计算，
        // 底部 section（如「重置数据」）被裁切、滚不到。
        // frame + autoresizingMask 由父控制器在布局时直接驱动，最鲁棒：
        // push 动画结束后 viewDidLayoutSubviews 会用最新 bounds 重算。
        let hostingController = UIHostingController(rootView: settingsView)
        hostingController.view.frame = view.bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        view.addSubview(hostingController.view)
        addChild(hostingController)
        hostingController.didMove(toParent: self)
    }
    
    @objc func openRepositoryUrl(_ sender: UIButton) {
        UIApplication.shared.open(URL(string: "https://github.com/zbzxbg/EeveeSpotifyReborn-ng")!)
    }
}
