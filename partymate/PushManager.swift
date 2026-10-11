import SwiftUI
import UserNotifications

/// Asks for notification permission and hands the device token to the app.
/// Delivery needs the Push Notifications capability and an APNs key (see SETUP.md).
@Observable
final class PushManager: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let shared = PushManager()

    /// Hex string Apple gives this install. Nil until registration succeeds.
    private(set) var deviceToken: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Call once the user has a profile; asking earlier just gets a reflexive "no".
    func requestPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected in the simulator and without the push capability. Nothing to do.
    }

    /// Show banners even while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}
