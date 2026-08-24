import Foundation

/// Finding a tmux pane from the tty a hook reported, and — the part that actually fixes the
/// long-standing bug — finding the *other* tty that the terminal emulator knows it by.
///
/// **A session running under tmux has two ttys, and everything downstream depends on knowing
/// which one you are holding.** The pane has one, and the client attached to it has another:
///
///     $ tmux list-panes   -a -F '#{pane_tty}|#{pane_id}|#{session_name}'
///     /dev/ttys005|%0|probe
///     $ tmux list-clients    -F '#{client_session}|#{client_tty}'
///     probe|/dev/ttys006
///
/// The hook reports `/dev/ttys005`: it walks up to its parent and asks `ps` for the controlling
/// terminal, which inside a pane is the pane's pty. iTerm2 and Terminal.app, meanwhile, know that
/// tab as `/dev/ttys006` — the client's pty is the one their window actually owns. So
/// `TerminalActivator`'s AppleScript, which compares the reported tty against `tty of s`, could
/// never match for anybody running tmux. It fell through to "bring whichever terminal is running
/// to the front", which lands on whatever tab happened to be showing. That is the entire bug.
///
/// Two things come out of resolving this, and they are independent:
///
/// - the **pane id**, which `select-pane` / `select-window` move to inside tmux — no permission
///   of any kind, because it is a subprocess rather than cross-app automation, and it is the only
///   route to the right pane for Ghostty, Warp, kitty, Alacritty, WezTerm and Hyper, none of
///   which expose a tab model to AppleScript at all
/// - the **client tty**, which is what the existing AppleScript path should have been given all
///   along, and which makes it land on the right tab for iTerm2 and Terminal.app
///
/// Parsing lives here, away from the process spawning, for the same reason `HTTPParser` does: the
/// bugs live in the parsing, and running the binary is not what needs testing.
public struct TmuxTarget: Equatable {
    /// `%0` — stable for the life of the pane, and what `select-pane` takes.
    public let paneID: String
    public let sessionName: String
    /// The tty the emulator knows this pane by, or nil when no client is attached — a detached
    /// session is still somewhere the pane can be selected, there is simply no window showing it.
    public let clientTTY: String?

    public init(paneID: String, sessionName: String, clientTTY: String?) {
        self.paneID = paneID
        self.sessionName = sessionName
        self.clientTTY = clientTTY
    }
}

public enum TmuxTargetResolver {

    /// The formats the app must ask tmux for. Kept beside the parser rather than at the call site
    /// so the tests drive the same strings production sends — a format changed in one place and
    /// not the other is exactly the kind of drift that shows up as "it stopped working" and
    /// nothing else.
    public static let paneFormat = "#{pane_tty}|#{pane_id}|#{session_name}"
    public static let clientFormat = "#{client_session}|#{client_tty}"

    /// Resolve a reported tty into the pane holding it.
    ///
    /// Returns nil when the tty is not a tmux pane at all, which is the ordinary case for somebody
    /// running Claude Code directly in a terminal — the caller then carries on with the tty it
    /// already had.
    public static func resolve(tty: String, panes: String, clients: String) -> TmuxTarget? {
        let wanted = normalize(tty)
        guard !wanted.isEmpty else { return nil }

        for line in panes.split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, normalize(f[0]) == wanted else { continue }
            let paneID = f[1].trimmingCharacters(in: .whitespaces)
            let session = f[2].trimmingCharacters(in: .whitespaces)
            guard !paneID.isEmpty else { continue }
            return TmuxTarget(paneID: paneID,
                              sessionName: session,
                              clientTTY: clientTTY(forSession: session, in: clients))
        }
        return nil
    }

    /// The first client attached to that session.
    ///
    /// More than one is legal — the same session can be attached from two windows — and there is
    /// no basis here for preferring either, so the first wins rather than the question being
    /// answered with a guess dressed up as a rule.
    static func clientTTY(forSession session: String, in clients: String) -> String? {
        guard !session.isEmpty else { return nil }
        for line in clients.split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, f[0].trimmingCharacters(in: .whitespaces) == session else { continue }
            let tty = f[1].trimmingCharacters(in: .whitespaces)
            if !tty.isEmpty { return tty }
        }
        return nil
    }

    /// Compare ttys by device name, so `/dev/ttys005` and `ttys005` are the same terminal.
    ///
    /// The two sides genuinely arrive in different shapes — tmux prints the full path, while `ps`
    /// prints the bare name and the hook re-adds the prefix — and a comparison that took either
    /// literally would match nothing while looking perfectly reasonable.
    static func normalize(_ tty: String) -> String {
        var s = tty.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("/dev/") { s.removeFirst("/dev/".count) }
        return s
    }
}

/// What happened when a tty was handed to tmux.
///
/// **Three outcomes, and they used to be two.** The bridge returned an optional: nil for "not a
/// tmux pane", a value for "selected, and here is the emulator's tty". But the emulator's tty is
/// nil for a *detached* session — and a detached session's pane still gets selected, which is the
/// whole reason every pane on the server is listed rather than the attached session's. So
/// selecting a pane on a detached server reported not finding one, while having just moved the
/// selection, and the log said so out loud.
///
/// Caught end to end by a test whose `tmux attach` had quietly exited: the message said nothing
/// was found and `window_active` moved anyway. The modelling is here rather than in the bridge
/// because conflating two facts in one optional is the kind of mistake a type can prevent and a
/// test can catch.
public enum TmuxRevealOutcome: Equatable, Sendable {
    /// Not a pane on any server that could be seen — no tmux, no server, or a session running
    /// straight in a terminal. The caller carries on with the tty it had.
    case notAPane
    /// The pane was selected. `emulatorTTY` is the tty a terminal emulator knows it by, or nil
    /// when no client is attached: nobody is looking at it, and the next attach lands there.
    case selected(emulatorTTY: String?)

    /// The tty to hand to the AppleScript route, given the one originally asked about.
    ///
    /// A selected pane with no client attached leaves AppleScript nothing to match, so the
    /// original is carried on with — tmux has already done its part.
    public func effectiveTTY(requested: String) -> String {
        switch self {
        case .selected(let emulator?): return emulator
        case .selected(nil), .notAPane: return requested
        }
    }

    /// Whether tmux aimed the pane, whatever AppleScript makes of it afterwards.
    public var didSelect: Bool {
        if case .selected = self { return true }
        return false
    }
}

/// One line saying what tmux did, without a prefix — callers add their own, because the same
/// sentence is written to the log and printed by `--reveal-tty`.
public func describeTmuxReveal(_ outcome: TmuxRevealOutcome, requested tty: String) -> String {
    switch outcome {
    case .notAPane:
        return "\(tty) is not a tmux pane"
    case .selected(let emulator?):
        return "selected the pane, emulator tty \(emulator)"
    case .selected(nil):
        return "selected the pane; no client attached, so nothing is showing it"
    }
}
