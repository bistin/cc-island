import AppKit
import DynamicIslandCore
import ServiceManagement

/// "Open at login" backed by `SMAppService.mainApp` (macOS 13+).
///
/// The system owns this state, not us — the user can flip it in System
/// Settings → General → Login Items at any time. So there is deliberately
/// no UserDefaults mirror: every read goes back to
/// `SMAppService.mainApp.status`, and `refresh()` is called whenever a
/// surface that displays it appears. A cached copy would let the UI claim
/// "on" for an app macOS has already stopped launching.
///
/// Decision logic (what a toggle flip should call, what the UI should say)
/// lives in `DynamicIslandCore.LoginItemState` so it can be unit-tested
/// without a live ServiceManagement registration.
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()

    @Published private(set) var status: LoginItemStatus
    /// Last `register()` / `unregister()` failure, cleared on the next attempt.
    @Published private(set) var lastError: String?

    var presentation: LoginItemPresentation { loginItemPresentation(for: status) }

    private init() {
        status = Self.readStatus()
    }

    /// Re-read the system's copy of the truth.
    func refresh() {
        status = Self.readStatus()
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil

        switch loginItemAction(for: status, desired: enabled) {
        case .register:
            attempt { try SMAppService.mainApp.register() }
        case .unregister:
            attempt { try SMAppService.mainApp.unregister() }
        case .none:
            break
        }

        // Always re-read: on `.requiresApproval` the call is a no-op and the
        // toggle must snap back to what macOS actually reports.
        refresh()
    }

    /// Deep-link into the pane where a `requiresApproval` veto is lifted.
    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            lastError = error.localizedDescription
            NSLog("[DynamicIsland] launch-at-login change failed: \(error)")
        }
    }

    private static func readStatus() -> LoginItemStatus {
        guard isBundledApp else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .notRegistered:    return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        @unknown default:       return .notRegistered
        }
    }

    /// `swift build` produces a bare executable whose `Bundle.main` is the
    /// containing directory — no `.app`, no login item. Calling
    /// `SMAppService.mainApp` there registers nothing useful, so the UI
    /// disables the toggle instead of failing at click time.
    private static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.bundleIdentifier != nil
    }
}
