import Foundation
import DynamicIslandCore

/// Talking to tmux, which is how a click on the island reaches a pane in a terminal that has no
/// AppleScript tab model at all.
///
/// `TerminalActivator` can address a tab in Terminal.app and iTerm2 and nowhere else, because
/// those are the only two that expose one. Ghostty, WezTerm, Warp, Hyper, kitty and Alacritty are
/// in its bundle-id list purely so that *something* comes forward; which tab you land on is
/// whatever happened to be showing. For anybody running tmux, this closes that: a pane can be
/// selected whichever emulator is drawing it.
///
/// **It needs no permission of any kind.** Not accessibility, not automation, no TCC prompt —
/// tmux is an ordinary subprocess, and asking it to change its own selection is not cross-app
/// automation. That is the whole reason this route is worth having over synthesising keystrokes.
///
/// Arguments go to `Process` as argv. Nothing is word-split and no shell is involved, so the tty —
/// which arrives over HTTP and is already narrowed by `decodeTTY` — cannot be a command here even
/// if that narrowing were ever loosened.
enum TmuxBridge {

    /// tmux is almost never on an app's `PATH`: an app launched from Finder or as a login item
    /// does not inherit a login shell, so `/opt/homebrew/bin` is simply not there. Probing the
    /// places package managers actually use costs four `stat` calls and avoids the entire class
    /// of "works from the terminal, does nothing from the app".
    static let candidatePaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
        "/opt/local/bin/tmux",
    ]

    static var binary: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Select the pane holding `tty`, and hand back the tty the *emulator* knows that pane by.
    ///
    /// nil means "not a tmux pane" — no tmux installed, no server running, or a session running
    /// straight in a terminal, which is the ordinary case. The caller then carries on with the tty
    /// it already had, so nothing is lost by tmux being absent.
    ///
    /// Runs three or four short subprocesses. Call it off the main thread; nothing here needs a
    /// run loop, and see ``TerminalActivator/activate(tty:)`` for why that ordering matters.
    static func reveal(tty: String) -> String? {
        guard let bin = binary else { return nil }
        // `-a`: every pane on the server, not only the attached session's. A detached session is
        // still a place a pane can be selected, and the next attach lands on it.
        guard let panes = run(bin, ["list-panes", "-a", "-F", TmuxTargetResolver.paneFormat]) else {
            return nil   // no server running: tmux exits non-zero, which is an answer, not an error
        }
        let clients = run(bin, ["list-clients", "-F", TmuxTargetResolver.clientFormat]) ?? ""
        guard let target = TmuxTargetResolver.resolve(tty: tty, panes: panes, clients: clients) else {
            return nil
        }
        // Both, and in this order: `select-pane` moves within the window, `select-window` brings
        // that window to the front of its session. Either alone leaves you looking at the wrong
        // half of the answer.
        _ = run(bin, ["select-pane", "-t", target.paneID])
        _ = run(bin, ["select-window", "-t", target.paneID])
        return target.clientTTY
    }

    /// nil on a non-zero exit or a launch failure. tmux uses the exit code to say "no server", so
    /// an empty-but-successful run and a failed one are deliberately not the same answer.
    private static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
