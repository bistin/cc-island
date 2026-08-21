import Foundation

/// The tmux server a session belongs to, read out of the `TMUX` environment variable.
///
/// **Only the default socket was visible before, and that is a real gap rather than a tidy-up.**
/// `TmuxBridge` runs `tmux` with no `-S`, which finds `/tmp/tmux-<uid>/default` and nothing else,
/// so anybody who starts their server with `tmux -L work` or `-S /path` got the old behaviour with
/// no indication why — the pane was simply never found.
///
/// The hook is the one part of this that runs *inside* the pane, so it is the only part that can
/// know. tmux sets `TMUX` there to `<socket-path>,<server-pid>,<session-index>`; measured on a
/// live server: `/private/tmp/tmux-501/probe-sock,36880,0`. The first field is the socket, and it
/// is an absolute path because tmux writes it as one.
///
/// Returns nil outside tmux, and for anything that is not an absolute path — the value reaches the
/// app in an HTTP payload, and while it goes to `Process` as argv rather than through a shell,
/// "looks like a socket path" is a cheaper thing to require than to reason about later.
public func tmuxSocketPath(fromTMUXEnv raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let socket = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    guard socket.hasPrefix("/"), !socket.contains("\0"), socket.count <= 1024 else { return nil }
    return socket
}
