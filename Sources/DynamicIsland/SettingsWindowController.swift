import AppKit
import SwiftUI

/// Hosts `SettingsView` in a regular `NSWindow`. Singleton-style — the
/// `AppDelegate` keeps the only strong reference (`settingsWindowController`),
/// without which the window would deallocate on first close. The window
/// also has `isReleasedWhenClosed = false` so closing it just hides it
/// instead of tearing down the SwiftUI host (#41 review).
final class SettingsWindowController: NSWindowController {
    /// Build a Settings window with `SettingsView` as content.
    static func make(stateManager: IslandStateManager) -> SettingsWindowController {
        let hosting = NSHostingController(
            rootView: SettingsView(stateManager: stateManager)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 360))
        window.center()
        return SettingsWindowController(window: window)
    }

    /// Bring the Settings window forward, activating the app if needed.
    /// Safe to call repeatedly — the window stays around between opens.
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
