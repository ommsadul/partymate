import SwiftUI

@main struct MyApp: App {
    @UIApplicationDelegateAdaptor(PushManager.self) private var pushManager

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
