import Foundation
import AppKit

/// Monitors macOS distributed notifications and forwards them to the Dynamic Island.
/// Uses NSWorkspace notifications for app-level events (app launch, sleep/wake, etc.)
/// and DistributedNotificationCenter for system-wide notifications.
class NotificationMonitor {
    static let shared = NotificationMonitor()
    private weak var stateManager: IslandStateManager?

    private init() {}

    func start(stateManager: IslandStateManager) {
        self.stateManager = stateManager

        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        // App activation
        workspace.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        // Volume change
        distributed.addObserver(
            self, selector: #selector(volumeChanged(_:)),
            name: NSNotification.Name("com.apple.sound.settingsChangedNotification"),
            object: nil
        )

        // Screen lock/unlock
        distributed.addObserver(
            self, selector: #selector(screenLocked(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil
        )
        distributed.addObserver(
            self, selector: #selector(screenUnlocked(_:)),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil
        )

        // System sleep/wake
        workspace.addObserver(
            self, selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        workspace.addObserver(
            self, selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        // Bluetooth/power (distributed)
        distributed.addObserver(
            self, selector: #selector(powerSourceChanged(_:)),
            name: NSNotification.Name("com.apple.system.powersources.timeremaining"),
            object: nil
        )
    }

    @objc private func appDidActivate(_ notification: Notification) {
        // Only show for noteworthy app switches — skip if same app or Finder
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let name = app.localizedName,
              name != "Finder",
              name != "DynamicIsland" else { return }

        // We don't push every app switch — it would be too noisy.
        // This is here as a hook point if the user wants to enable it.
    }

    @objc private func volumeChanged(_ notification: Notification) {
        stateManager?.pushEvent(IslandEvent(
            icon: "🔊",
            title: "Volume Changed",
            style: .info,
            duration: 2.0
        ))
    }

    @objc private func screenLocked(_ notification: Notification) {
        stateManager?.pushEvent(IslandEvent(
            icon: "🔒",
            title: "Screen Locked",
            style: .info,
            duration: 2.0
        ))
    }

    @objc private func screenUnlocked(_ notification: Notification) {
        stateManager?.pushEvent(IslandEvent(
            icon: "🔓",
            title: "Welcome Back",
            style: .success,
            duration: 2.0
        ))
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        stateManager?.pushEvent(IslandEvent(
            icon: "😴",
            title: "Sleep",
            style: .info,
            duration: 1.5
        ))
    }

    @objc private func systemDidWake(_ notification: Notification) {
        stateManager?.pushEvent(IslandEvent(
            icon: "☀️",
            title: "Awake",
            subtitle: "Good to see you!",
            style: .success,
            duration: 2.5
        ))
    }

    @objc private func powerSourceChanged(_ notification: Notification) {
        stateManager?.pushEvent(IslandEvent(
            icon: "🔋",
            title: "Power Changed",
            style: .info,
            duration: 2.5
        ))
    }
}
