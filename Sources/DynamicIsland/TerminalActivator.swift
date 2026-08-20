import AppKit
import Foundation

/// Bring the terminal tab whose controlling TTY matches `tty` to the front.
///
/// Used by the ear / capsule tap handler so a click on the island jumps to
/// the actual terminal pane running Claude Code.
///
/// Three routes, tried in that order:
///
/// - **tmux**, via ``TmuxBridge`` — selects the pane whichever emulator is
///   drawing it, needs no permission at all, and is the only route to the
///   right pane for Ghostty, WezTerm, Warp, Hyper, kitty and Alacritty,
///   none of which expose a tab model to AppleScript. It also translates
///   the pane's tty into the one the emulator knows the tab by, which is
///   what makes the AppleScript route below work for tmux users at all.
/// - **AppleScript** against Terminal.app and iTerm2, the two terminals
///   with a rich tab model.
/// - **Activate whatever terminal is running**, so the user at least gets
///   back to *a* terminal.
///
/// Safety: `tty` is decoded by `decodeTTY` upstream, which only admits
/// `/dev/ttys<digits>` or `/dev/pts/<digits>`. That keeps the AppleScript
/// interpolation below from being a shell-injection sink even though the
/// payload originates from an HTTP POST. The tmux route passes it as argv
/// with no shell, so it is not a sink there under any narrowing.
enum TerminalActivator {
    /// Cheap synchronous check: is any supported terminal app currently
    /// running? Called on the main thread before `activate(tty:)` so the
    /// tap handler can fall back to `expand()` when there's no terminal
    /// to switch to (instead of silently dismissing the island).
    static func hasRunningTerminal() -> Bool {
        firstRunningTerminalBundleID() != nil
    }

    /// Fire-and-forget: focus the terminal tab whose controlling TTY
    /// matches `tty`.
    ///
    /// **Two phases, on two queues, and the split is not cosmetic.**
    ///
    /// tmux first, off the main thread. A session running under tmux has
    /// *two* ttys — the pane's, which is what the hook reports, and the
    /// client's, which is what an emulator knows the tab by — and they are
    /// different numbers. Every AppleScript lookup below compares against
    /// the reported tty, so before this existed none of them could ever
    /// match for a tmux user: the whole thing fell through to "bring some
    /// terminal forward", landing on whatever tab happened to be showing.
    /// `TmuxBridge.reveal` selects the right pane and hands back the tty
    /// the emulator actually owns. It is a subprocess, needs no run loop
    /// and no TCC permission, and must not sit on the main thread.
    ///
    /// Then AppleScript, on main: NSAppleScript from a background queue has
    /// no CFRunLoop and silently swallows the AppleEvent dispatch + TCC
    /// permission prompt; NSWorkspace.runningApplications is also
    /// documented main-thread-only. Hopping back also means the caller's
    /// dismiss animation has started before AppleScript blocks (~100-500ms
    /// on iTerm2 with many windows).
    ///
    /// Callers must precheck `hasRunningTerminal()` — when no terminal is
    /// running we do nothing here, leaving the UI decision (expand vs
    /// dismiss) to the caller.
    static func activate(tty: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            // nil means "not a tmux pane", which is the ordinary case; carry
            // on with the tty we were given rather than giving up.
            let emulatorTTY = TmuxBridge.reveal(tty: tty) ?? tty
            DispatchQueue.main.async { activateFrontmost(tty: emulatorTTY) }
        }
    }

    /// The same two routes, run synchronously on the calling thread, for `--reveal-tty`.
    ///
    /// It exists because the click path had no way to be exercised without a person clicking, and
    /// "hand the user a build and ask them to try it" is the shape of testing this project tries
    /// not to do. A CLI invocation has a main thread but no running run loop, so the async hop in
    /// ``activate(tty:)`` would exit before it did anything; this does both halves in order and
    /// reports which one answered.
    ///
    /// Returns a line describing what happened, for a person reading it in a terminal.
    static func revealSynchronously(tty: String) -> String {
        let tmuxTTY = TmuxBridge.reveal(tty: tty)
        let effective = tmuxTTY ?? tty
        var notes = tmuxTTY.map { "tmux: pane selected, emulator knows it as \($0)" }
            ?? "tmux: not a pane (no server, non-default socket, or not under tmux)"

        let runningIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )
        if runningIDs.contains("com.apple.Terminal"), runScript(terminalAppScript(tty: effective)) {
            notes += "\napplescript: Terminal.app tab matched \(effective)"
            return notes
        }
        if runningIDs.contains("com.googlecode.iterm2"), runScript(iTermScript(tty: effective)) {
            notes += "\napplescript: iTerm2 session matched \(effective)"
            return notes
        }
        notes += "\napplescript: no tab matched \(effective)"
        notes += tmuxTTY == nil
            ? " — nothing more to try"
            : " — expected for a terminal with no tab model; tmux already aimed the pane"
        return notes
    }

    /// The AppleScript half. Main thread only — see ``activate(tty:)``.
    private static func activateFrontmost(tty: String) {
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
        // No tab matched — either the terminal has no AppleScript tab model
        // at all, or tmux already put the right pane in front of a window we
        // cannot address. Surface whichever terminal is running so the user
        // lands somewhere familiar; under tmux that is now the right pane.
        if let fallbackID = knownTerminalBundleIDs
            .first(where: { runningIDs.contains($0) }) {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == fallbackID }?
                .activate(options: [.activateAllWindows])
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
