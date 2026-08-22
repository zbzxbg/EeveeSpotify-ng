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

        // Do NOT pin the SwiftUI view to the full navigationController frame here.
        // That fixed frame is larger than this controller's visible area once the
        // nav bar / home indicator are accounted for, so the List's scroll range
        // is wrong and the last sections get clipped off-screen ("只能到这").
        // Instead pin the hosting view to this controller's bounds so the List
        // scrolls within the actual visible area.
        let hostingController = UIHostingController(rootView: settingsView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(hostingController.view)
        addChild(hostingController)
        hostingController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
    
    @objc func openRepositoryUrl(_ sender: UIButton) {
        UIApplication.shared.open(URL(string: "https://github.com/zbzxbg/EeveeSpotifyReborn-ng")!)
    }
}
