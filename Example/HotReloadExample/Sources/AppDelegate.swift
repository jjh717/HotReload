import UIKit

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

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UINavigationController(rootViewController: ExampleViewController())
        window?.makeKeyAndVisible()

        return true
    }
}
