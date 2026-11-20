import SwiftUI

@main
struct StikDebugApp: App {
    init() {
        AppBootstrapper.configure()
    }

    var body: some Scene {
        WindowGroup {
            LocationRootView()
        }
    }
}
