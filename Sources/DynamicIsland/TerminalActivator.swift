import AppKit
import Foundation

/// Bring the terminal tab whose controlling TTY matches `tty` to the front.
///
/// Used by the ear / capsule tap handler so a click on the island jumps to
/// the actual terminal pane running Claude Code. Works against Terminal.app
/// and iTerm2 (the two terminals with rich AppleScript tab support); for
/// everything else we fall back to activating whatever terminal app is
/// frontmost so the user at least gets back to *a* terminal.
///
/// Safety: `tty` is decoded by `decodeTTY` upstream, which only admits
/// `/dev/ttys<digits>` or `/dev/pts/<digits>`. That keeps the AppleScript
/// interpolation below from being a shell-injection sink even though the
/// payload originates from an HTTP POST.
enum TerminalActivator {
    /// Cheap synchronous check: is any supported terminal app currently
    /// running? Called on the main thread before `activate(tty:)` so the
    /// tap handler can fall back to `expand()` when there's no terminal
    /// to switch to (instead of silently dismissing the island).
    static func hasRunningTerminal() -> Bool {
        firstRunningTerminalBundleID() != nil
    }

    /// Fire-and-forget: focus the terminal tab whose controlling TTY
    /// matches `tty`. Async-dispatched on the main queue so the caller's
    /// dismiss animation gets to start before AppleScript blocks
    /// (~100-500ms on iTerm2 with many windows).
    ///
    /// Must run on main: NSAppleScript from a background queue has no
    /// CFRunLoop and silently swallows the AppleEvent dispatch + TCC
    /// permission prompt; NSWorkspace.runningApplications is also
    /// documented main-thread-only.
    ///
    /// Callers must precheck `hasRunningTerminal()` — when no terminal is
    /// running we do nothing here, leaving the UI decision (expand vs
    /// dismiss) to the caller.
    static func activate(tty: String) {
        DispatchQueue.main.async {
            let runningIDs = Set(
                NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
            )
            if runningIDs.contains("com.apple.Terminal"),
               runScript(terminalAppScript(tty: tty)) {
                return
            }
            if runningIDs.contains("com.googlecode.iterm2"),
               runScript(iTermScript(tty: tty)) {
                // AppleScript `activate` doesn't reliably surface
                // fullscreen-Space iTerm windows from an LSUIElement
                // caller — belt-and-suspenders with NSWorkspace.
                NSWorkspace.shared.runningApplications
                    .first { $0.bundleIdentifier == "com.googlecode.iterm2" }?
                    .activate(options: [.activateAllWindows])
                return
            }
            // No tab matched. Surface whichever terminal app is running
            // so the user lands somewhere familiar.
            if let fallbackID = knownTerminalBundleIDs
                .first(where: { runningIDs.contains($0) }) {
                NSWorkspace.shared.runningApplications
                    .first { $0.bundleIdentifier == fallbackID }?
                    .activate(options: [.activateAllWindows])
            }
        }
    }

    // MARK: - AppleScript sources

    /// Terminal.app exposes `tty` directly on each tab. Setting `selected`
    /// switches to it and `frontmost` raises the window. Returns true on
    /// match so the calling NSAppleScript run flips its result code.
    private static func terminalAppScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set frontmost of w to true
                            activate
                            return true
                        end if
                    end try
                end repeat
            end repeat
            return false
        end tell
        """
    }

    /// iTerm2 nests sessions under tabs under windows, with `tty` on the
    /// session. `select` raises the session's tab and window in one go.
    private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s is "\(tty)" then
                                tell w
                                    select t
                                end tell
                                select s
                                activate
                                return true
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """
    }

    // MARK: - NSAppleScript runner

    private static func runScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var errorDict: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorDict)
        if errorDict != nil { return false }
        // The scripts above return a boolean; bridge it back. AppleScript
        // booleans surface as `typeBoolean` (1/0) in NSAppleEventDescriptor.
        return descriptor.booleanValue
    }

    // MARK: - App discovery

    /// Bundle IDs of the most common macOS terminal apps. Order doesn't
    /// matter — any one being frontmost is good enough for the fallback.
    private static let knownTerminalBundleIDs: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "io.alacritty",
    ]

    private static func firstRunningTerminalBundleID() -> String? {
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )
        return knownTerminalBundleIDs.first { running.contains($0) }
    }
}
