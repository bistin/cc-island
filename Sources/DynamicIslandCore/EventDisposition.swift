import Foundation

/// Coarse style category that matters to the event dispatch logic.
/// `IslandStateManager.pushEvent` doesn't care about the full
/// `EventStyle` palette — only whether the event represents a
/// long-polling decision (`.action`), a long-polling reminder
/// (`.reminder` carrying a `replyMode`), or a transient ping (anything
/// else). Mapping to this shape is the caller's responsibility.
public enum EventStyleShape: Equatable, Sendable {
    case action
    case reminder
    case other
}

/// Pure-data view of an `IslandEvent` for the dispatch decision —
/// just the fields `decideEventDisposition` actually inspects.
/// Decouples the helper from `IslandEvent` (which depends on SwiftUI
/// `Color`) so this file lives in `DynamicIslandCore`.
public struct EventSnapshot: Equatable, Sendable {
    public let title: String
    public let style: EventStyleShape
    public let hasReplyMode: Bool
    /// Set on events that do not dismiss themselves. On a `reminder` this is what says "somebody
    /// is being asked and has not answered", which is the difference between a ping and a wait.
    public let isPersistent: Bool
    public let hasProgress: Bool
    public let sessionID: String?
    public let agentID: String?
    public let project: String?

    public init(
        title: String,
        style: EventStyleShape,
        hasReplyMode: Bool,
        isPersistent: Bool = false,
        hasProgress: Bool,
        sessionID: String?,
        agentID: String?,
        project: String?
    ) {
        self.title = title
        self.style = style
        self.hasReplyMode = hasReplyMode
        self.isPersistent = isPersistent
        self.hasProgress = hasProgress
        self.sessionID = sessionID
        self.agentID = agentID
        self.project = project
    }
}

/// What the state manager should do with an incoming event given the
/// current one's state.
public enum EventDisposition: Equatable, Sendable {
    /// Same-title progress update — merge in place without re-animating.
    case mergeProgress
    /// Current event is mid-decision; queue the incoming behind it.
    case queueAsAction
    /// Current event is mid-decision and the incoming is a transient
    /// ping from a different session — drop on the floor.
    case dropTransient
    /// No protection in effect; show the incoming, replacing whatever
    /// (if anything) is on screen.
    case showImmediately
}

/// Decide what to do with an incoming event.
///
/// Semantics carved out of `IslandStateManager.pushEvent` so the
/// stack of guards from #28 (action queue), #31 (expired release),
/// and #32 (same-session takeover) can be exercised by unit tests.
///
/// Order of checks must match `pushEvent`'s original flow:
///
/// 1. **Progress merge** — if both events share `title` and carry a
///    `progress` value, swap in place. This wins over every other
///    rule including the decision guard.
/// 2. **In-decision guard** — when the current event represents a
///    long-polling decision (`.action`, or `.reminder` with a reply
///    mode) *and* its long-poll horizon hasn't expired:
///    - Same-session non-decision incoming → release the lock and
///      show (#32 takeover).
///    - Any decision-shaped incoming → queue.
///    - Cross-session transient incoming → drop.
/// 3. Otherwise — show.
public func decideEventDisposition(
    current: EventSnapshot?,
    currentExpired: Bool,
    incoming: EventSnapshot
) -> EventDisposition {
    if let current,
       current.title == incoming.title,
       current.hasProgress,
       incoming.hasProgress {
        return .mergeProgress
    }

    // What counts as "a person is mid-decision, do not bury this".
    //
    // A persistent `reminder` belongs here and did not used to, which was a real hole: an
    // `AskUserQuestion` waiting on somebody is the same claim on their attention as an Allow/Deny,
    // and without this the very next tool call from *any* session — a Bash from a different
    // project, a Read from a subagent — replaced it and the question vanished from the island
    // while it was still on screen in the terminal. Observed while testing #66.
    //
    // Same-session events still take over, which is deliberate and is also the clearing path:
    // a session that has moved on to its next tool is a session whose question got answered.
    func isDecisionShape(_ e: EventSnapshot) -> Bool {
        e.style == .action
            || (e.style == .reminder && (e.hasReplyMode || e.isPersistent))
    }

    let curIsDecision = !currentExpired && (current.map(isDecisionShape) ?? false)
    guard curIsDecision, let current else {
        return .showImmediately
    }

    let incomingIsDecision = isDecisionShape(incoming)
    let sameSession = isSameSession(a: incoming, b: current)

    if !incomingIsDecision, sameSession {
        return .showImmediately
    }
    if incomingIsDecision {
        return .queueAsAction
    }
    return .dropTransient
}

/// Two snapshots count as "same session" when they share Claude's
/// session UUID, or when both lack one but agree on `(project,
/// agentID)`. Lifted from `IslandStateManager.isSameSession` (#32).
public func isSameSession(a: EventSnapshot, b: EventSnapshot) -> Bool {
    if let sa = a.sessionID, let sb = b.sessionID {
        return sa == sb
    }
    return a.project == b.project && a.agentID == b.agentID
}

/// Whether an event should open already expanded, rather than as ears the user has to click.
///
/// **The rule is: something that pulses, and has something to show, shows it.** An event that
/// pulses is asking for a person; if it also carries a detail, that detail is what tells them
/// whether it is worth crossing the room for. Making them click first is asking them to act on
/// "something wants you" alone, which is the least useful half of the message.
///
/// - `action` opens expanded because its detail *is* the decision — Allow/Deny sit in it.
/// - A `reminder` with a detail is a question with its options, a plan with its body, or a turn
///   that ended on a question with the message that ended it. All three are "here is what you
///   would be deciding".
/// - A `reminder` with nothing to show — the bare `Notification` ping — stays as ears. Expanding
///   an empty panel would cover the screen to say nothing.
///
/// Deliberately **not** paired with an expiry. `action` expires because its hook stops
/// long-polling and a late click cannot land; a question has no such horizon, and 58 of them on
/// one machine were answered at a median of 71 seconds and a maximum of 10.9 hours. Dismissing
/// the marker while the question is still on screen would defeat the entire point. What clears it
/// instead is arrival: the matching `PostToolUse`, or the session's next event, or its `Stop` —
/// any of which replaces it.
public func shouldOpenExpanded(
    style: EventStyleShape,
    hasDetail: Bool,
    hasReplyMode: Bool
) -> Bool {
    if style == .action { return true }
    if hasReplyMode { return true }
    return style == .reminder && hasDetail
}

/// Whether tapping this event should take the user to its terminal, rather than dismissing or
/// collapsing it.
///
/// **The question a tap answers is "I want to deal with this", and where that leads depends on
/// whether the island can do anything about it.** When the island holds the decision — Allow/Deny,
/// or quick-reply buttons — the answer is right there and leaving would be the wrong move. When it
/// does not, the island is a pointer, and the useful thing a pointer can do is take you to the
/// thing it points at.
///
/// That second case is what a waiting event is. `AskUserQuestion` and `ExitPlanMode` put a menu in
/// the terminal and nothing on the island, so a tap that merely dismissed the marker threw away
/// the one thing the user was reaching for — and threw away the only record that they were being
/// asked at all.
public func shouldTapJumpToTerminal(
    style: EventStyleShape,
    hasReplyMode: Bool,
    hasTTY: Bool,
    clickToTerminalEnabled: Bool
) -> Bool {
    guard hasTTY, clickToTerminalEnabled else { return false }
    // The decision lives on the island; do not walk away from it.
    if style == .action || hasReplyMode { return false }
    return true
}

/// Extra height the expanded panel needs beyond its base, in points.
///
/// **The base reserves room for about three lines of detail and nothing else, which is why a
/// permission dialog lost its diff entirely.** An `action` event stacks two rows of controls under
/// the detail — Allow/Deny, and the jump-to-terminal row — and none of that was in the
/// arithmetic, so the space came out of the detail. The detail is rendered in a `ScrollView` with
/// a maximum height and no minimum, which does not clip when it is squeezed: it collapses to
/// nothing. The panel looked deliberate, and the diff the whole dialog exists to show you was
/// simply absent.
///
/// Found while taking screenshots for the README, by noticing that the same payload rendered its
/// diff as a `reminder` and rendered nothing as an `action`.
public func expandedPanelExtraHeight(
    sessionRows: Int,
    detailLines: Int,
    decisionRows: Int
) -> CGFloat {
    let tree: CGFloat = sessionRows >= 2 ? CGFloat(sessionRows) * 18 + 12 : 0
    let detail: CGFloat = detailLines > 3 ? CGFloat(detailLines - 3) * 14 : 0
    // Each row of controls is a 44pt tap target plus the gap above it. Counted rather than
    // folded into the base, so a layout that grows a third row cannot quietly take the space
    // back out of the detail.
    let decisions: CGFloat = CGFloat(max(0, decisionRows)) * 52
    return tree + detail + decisions
}

/// How many session rows to draw, and how many to report as not drawn.
///
/// **A tree with no ceiling is a panel with no ceiling.** Rows are 18 points each and the height
/// arithmetic multiplied by however many there were, so fourteen subagents produced a panel taller
/// than the screen with its last rows cut off — including, in the case that prompted this, the
/// question the user was being asked, pushed up and away by things that had already finished.
///
/// The cap is a floor under correctness rather than a substitute for it: what put fourteen rows
/// there was a close path that never fired, and that is fixed separately. This is what keeps the
/// next leak from being unbounded.
///
/// Five, because the main session takes one and four is enough parallel work to see at a glance.
/// Past that the count carries more than the names do, especially when a workflow spawns agents
/// that all share one type and so all render the same label.
public func sessionRowsToShow(total: Int, limit: Int = 5) -> (shown: Int, hidden: Int) {
    guard total > limit else { return (max(0, total), 0) }
    // One row is given up to the "and N more" line, so the drawn count never exceeds the limit.
    return (limit - 1, total - (limit - 1))
}
