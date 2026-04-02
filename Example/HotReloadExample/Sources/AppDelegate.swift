import UIKit
import SwiftUI

#if DEBUG && targetEnvironment(simulator)
import HotReloadClient
#endif

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        #if DEBUG && targetEnvironment(simulator)
        HotReloadClient.start()
        #endif

        let uikitVC = ExampleViewController()
        uikitVC.tabBarItem = UITabBarItem(title: "UIKit", image: UIImage(systemName: "hammer"), tag: 0)

        let swiftUIVC = UIHostingController(rootView: ExampleSwiftUIView())
        swiftUIVC.tabBarItem = UITabBarItem(title: "SwiftUI", image: UIImage(systemName: "swift"), tag: 1)

        let tabBar = UITabBarController()
        tabBar.viewControllers = [
            UINavigationController(rootViewController: uikitVC),
            UINavigationController(rootViewController: swiftUIVC),
        ]

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = tabBar
        window?.makeKeyAndVisible()

        return true
    }
}
