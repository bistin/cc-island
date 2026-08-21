import Foundation

/// What this build of CLI Island assumes about the things it reads, and what breaks when one of
/// those assumptions stops being true.
///
/// **Almost none of this is an API.** Claude Code writes a transcript, runs hooks in an order and
/// with a payload shape, names its tools, and reports a controlling terminal through `ps`; tmux
/// prints format strings and exports `TMUX`; macOS reports a notch and a login-item status. This
/// app reads all of it, and nobody promised to keep any of it still. That is a reasonable way to
/// build this and a bad thing to leave undocumented, because **every one of these breaking looks
/// like this app being broken**: an island that never lights up, a click that goes nowhere, a
/// toggle that lies.
///
/// So the assumptions are data rather than a paragraph somebody meant to write, `--compat-table`
/// prints them, and `docs/compatibility.md` is generated from this same list. A compatibility page
/// maintained by hand is a page that is wrong by the second release.
public enum Compat {

    /// One thing this app reads that it was never promised would stay the same.
    public struct Dependency: Equatable, Sendable {
        /// What it is, in the words somebody debugging would use.
        public let what: String
        /// Where it is read.
        public let source: String
        /// **The useful column.** What you would see if it changed — because every one of these
        /// failures is quiet, and every one of them looks like a bug in this app rather than a
        /// change underneath it.
        public let symptom: String
        /// What it was last confirmed against.
        ///
        /// "measured" means somebody ran it and wrote down the result; the measurement is in
        /// `CLAUDE.md`. "assumed" means it has been true for as long as anyone looked and nobody
        /// has gone back to find where it started — which is honest, where inventing a version
        /// would make this column mean "probably".
        public let confirmed: String

        public init(what: String, source: String, symptom: String, confirmed: String) {
            self.what = what
            self.source = source
            self.symptom = symptom
            self.confirmed = confirmed
        }
    }

    public static let dependencies: [Dependency] = [
        Dependency(
            what: "Hook payload field names — `hook_event_name`, `tool_name`, `tool_input`, `session_id`, `cwd`",
            source: "IslandHookCore/HookPlan.swift",
            symptom: "Nothing appears on the island at all, from any session",
            confirmed: "assumed"),
        Dependency(
            what: "`PreToolUse` runs before the tool does, and has no tool matcher",
            source: "IslandHookCore/PayloadBuilder.swift, HookInstaller.swift",
            symptom: "\"Waiting for you\" never appears, or appears only after the person answered",
            confirmed: "measured 2026-08-20 — the POST arrived 18.3 s before the answer"),
        Dependency(
            what: "The tools that ask a person are named `AskUserQuestion` and `ExitPlanMode`",
            source: "IslandHookCore/PayloadBuilder.swift (`InteractiveTools`)",
            symptom: "A menu or a plan waits with nothing on the island to say so",
            confirmed: "assumed"),
        Dependency(
            what: "`PermissionRequest` accepts a decision on stdout as `hookSpecificOutput.decision.behavior`",
            source: "island-hook/main.swift",
            symptom: "Allow/Deny on the island does nothing and the terminal prompt appears anyway",
            confirmed: "assumed"),
        Dependency(
            what: "A `Stop` hook returning `decision: block` feeds `reason` back as the user's next turn",
            source: "IslandHookCore/StopReply.swift",
            symptom: "Quick replies are swallowed — the session ends instead of continuing",
            confirmed: "assumed"),
        Dependency(
            what: "The session transcript: one JSONL file per session under `~/.claude/projects/`",
            source: "DynamicIslandCore/TranscriptState.swift",
            symptom: "Session state is always `unknown`",
            confirmed: "measured 2026-08-20 across 31 transcripts"),
        Dependency(
            what: "A turn ends with a `system` entry whose `subtype` is `turn_duration`",
            source: "DynamicIslandCore/TranscriptState.swift",
            symptom: "Finished sessions read as still working until they go stale",
            confirmed: "measured 2026-08-20"),
        Dependency(
            what: "An assistant `tool_use` and its `tool_result` are written together, after the tool returns",
            source: "DynamicIslandCore/TranscriptState.swift (why there is no `waiting` case)",
            symptom: "If this changed, a pending question would become readable from the transcript — an opportunity, not a break",
            confirmed: "measured 2026-08-20 — three samples, 26/32/54 s behind a live call"),
        Dependency(
            what: "The project directory turns every non-alphanumeric character into a dash",
            source: "DynamicIslandCore/TranscriptState.swift (`projectSlug`)",
            symptom: "A session's transcript is never found — and silently, because a missing transcript is an ordinary state",
            confirmed: "measured 2026-08-20 — `~/Desktop/毒` lives at `-Users-…-Desktop--`"),
        Dependency(
            what: "`ps -o tty=` reports the controlling terminal as a bare `ttysNNN`",
            source: "IslandHookCore/TTYDetect.swift",
            symptom: "Clicking an event brings a terminal forward but lands on whatever tab was showing",
            confirmed: "assumed"),
        Dependency(
            what: "tmux format strings `#{pane_tty}` / `#{pane_id}` / `#{session_name}` / `#{client_tty}`",
            source: "DynamicIslandCore/TmuxTarget.swift",
            symptom: "The tmux route silently does nothing and the click falls back to activating an app",
            confirmed: "measured 2026-08-20"),
        Dependency(
            what: "`TMUX` inside a pane is `<socket-path>,<server-pid>,<session-index>`",
            source: "IslandHookCore/TmuxSocket.swift",
            symptom: "Panes on a `tmux -L name` server cannot be reached; default-socket ones still work",
            confirmed: "measured 2026-08-21"),
        Dependency(
            what: "Terminal.app exposes `tty` on a tab, iTerm2 on a session, both selectable by AppleScript",
            source: "DynamicIsland/TerminalActivator.swift",
            symptom: "Clicking cannot reach a tab in those two; tmux users are unaffected",
            confirmed: "assumed"),
        Dependency(
            what: "`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` bracket the notch",
            source: "DynamicIsland/IslandPanel.swift",
            symptom: "The ears sit at the wrong width, or a notched display is drawn as a capsule",
            confirmed: "assumed"),
        Dependency(
            what: "`SMAppService.mainApp.status` distinguishes `notFound` from `requiresApproval`",
            source: "DynamicIslandCore/LoginItemState.swift",
            symptom: "The startup toggle reports a state the system does not agree with",
            confirmed: "measured on macOS 26.5.2"),
    ]

    /// The table as `docs/compatibility.md`. Generated rather than written, so the page and the
    /// code cannot drift; `scripts/check-compatibility-doc.sh` fails the build when they have.
    public static func markdown() -> String {
        var out = """
        <!-- Generated by `DynamicIsland --compat-table` from Sources/DynamicIslandCore/Compat.swift.
             Do not edit by hand: scripts/check-compatibility-doc.sh will fail. -->

        # What this depends on, and what breaks when it changes

        Almost nothing below is an API. Claude Code writes a transcript, runs hooks in an order and
        with a payload shape, and names its tools; tmux prints format strings; macOS reports a notch
        and a login-item status. CLI Island reads all of it, and nobody promised to keep any of it
        still.

        **The symptom column is the useful one.** Every failure here is quiet, and every one of them
        looks like a bug in this app rather than a change underneath it — so if something on this
        page describes what you are seeing, start there.

        | What | Where | If it changes, you see | Confirmed |
        |---|---|---|---|

        """
        for d in dependencies {
            out += "| \(d.what) | `\(d.source)` | \(d.symptom) | \(d.confirmed) |\n"
        }
        out += """

        ## On "assumed"

        It means the thing has been true for as long as anyone looked, and nobody has gone back to
        find the version it started in. That is the honest answer; inventing a version number would
        make this column mean "probably". "measured" means somebody ran it and wrote down the
        result — the measurement is in `CLAUDE.md`.
        """
        return out + "\n"
    }
}
