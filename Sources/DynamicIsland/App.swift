import AppKit
import SwiftUI

@main
struct DynamicIslandApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Hide from dock
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: IslandPanel!
    var stateManager = IslandStateManager()
    var server: LocalServer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = IslandPanel(stateManager: stateManager)
        panel.show()

        server = LocalServer(stateManager: stateManager)
        server.start()

        NotificationMonitor.shared.start(stateManager: stateManager)

        // Show welcome message
        stateManager.pushEvent(IslandEvent(
            icon: "🏝️",
            title: "Dynamic Island",
            subtitle: "Ready — listening on port \(server.port)",
            style: .info,
            duration: 3.0
        ))
    }
}
