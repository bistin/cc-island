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
    public let hasProgress: Bool
    public let sessionID: String?
    public let agentID: String?
    public let project: String?

    public init(
        title: String,
        style: EventStyleShape,
        hasReplyMode: Bool,
        hasProgress: Bool,
        sessionID: String?,
        agentID: String?,
        project: String?
    ) {
        self.title = title
        self.style = style
        self.hasReplyMode = hasReplyMode
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

    func isDecisionShape(_ e: EventSnapshot) -> Bool {
        e.style == .action || (e.style == .reminder && e.hasReplyMode)
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
