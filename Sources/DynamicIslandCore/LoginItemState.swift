import Foundation

/// Platform-agnostic mirror of `ServiceManagement.SMAppService.Status`,
/// plus the one state that API can't express: the app isn't running from
/// an `.app` bundle at all (a bare `swift build` binary), so there is no
/// login item to register.
///
/// The app layer maps `SMAppService.Status` onto this with an explicit
/// switch rather than a `rawValue` bridge — Apple's raw values are not
/// documented API, and a silent reordering would flip the UI's meaning.
public enum LoginItemStatus: Equatable, Sendable {
    /// Registered and allowed to launch at login.
    case enabled
    /// Never registered, or explicitly unregistered by us.
    case notRegistered
    /// Registered, but the user switched it off in System Settings.
    /// Re-registering does not clear this — only the user can.
    case requiresApproval
    /// macOS has no login-item record for this bundle. Despite the alarming
    /// name this is the ordinary never-registered state — a freshly built
    /// `.app` in /Applications reports `notFound`, not `notRegistered`, on
    /// macOS 26 (verified on 26.5.2, including after `lsregister -f`). So it
    /// is presented as a plain "off", not as an error.
    case notFound
    /// Not running from an `.app` bundle, so `SMAppService` doesn't apply.
    case unavailable
}

/// What to actually do when the user flips the toggle.
///
/// Split out from the UI so the "don't re-register on `requiresApproval`"
/// rule is verifiable without a live `SMAppService`. Re-registering there
/// succeeds at the API level but leaves the status unchanged, which reads
/// to the user as a toggle that silently springs back.
public enum LoginItemAction: Equatable, Sendable {
    case register
    case unregister
    /// Nothing useful to call — the UI explains why via `LoginItemPresentation`.
    case none
}

public func loginItemAction(for status: LoginItemStatus, desired: Bool) -> LoginItemAction {
    switch (status, desired) {
    case (.enabled, true), (.notRegistered, false), (.notFound, false), (.unavailable, _):
        return .none
    case (.notRegistered, true), (.notFound, true):
        return .register
    case (.enabled, false), (.requiresApproval, false):
        return .unregister
    case (.requiresApproval, true):
        // Already registered; only the user can lift the veto.
        return .none
    }
}

/// Everything the Settings toggle needs to render, derived from status.
public struct LoginItemPresentation: Equatable, Sendable {
    /// Where the toggle knob sits.
    public let isOn: Bool
    /// Whether flipping it can accomplish anything.
    public let isInteractive: Bool
    /// Explanation shown under the toggle, when the state needs one.
    public let message: String?
    /// Whether to offer a shortcut into System Settings → Login Items.
    public let showsSystemSettingsButton: Bool

    public init(
        isOn: Bool,
        isInteractive: Bool,
        message: String?,
        showsSystemSettingsButton: Bool
    ) {
        self.isOn = isOn
        self.isInteractive = isInteractive
        self.message = message
        self.showsSystemSettingsButton = showsSystemSettingsButton
    }
}

public func loginItemPresentation(for status: LoginItemStatus) -> LoginItemPresentation {
    switch status {
    case .enabled:
        return LoginItemPresentation(
            isOn: true, isInteractive: true,
            message: nil, showsSystemSettingsButton: false
        )
    case .notRegistered, .notFound:
        return LoginItemPresentation(
            isOn: false, isInteractive: true,
            message: nil, showsSystemSettingsButton: false
        )
    case .requiresApproval:
        return LoginItemPresentation(
            isOn: false, isInteractive: true,
            message: "CLI Island is registered, but login items are "
                + "switched off for it in System Settings. Turn it back on "
                + "there — this toggle can't override that.",
            showsSystemSettingsButton: true
        )
    case .unavailable:
        return LoginItemPresentation(
            isOn: false, isInteractive: false,
            message: "Launch at login needs the bundled DynamicIsland.app. "
                + "This is a bare `swift build` binary, which macOS has no "
                + "login item for.",
            showsSystemSettingsButton: false
        )
    }
}
