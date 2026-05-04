import DynamicIslandCore
import Foundation
import SwiftUI
import IslandHookCore

// MARK: - Event Model

/// Suggested permission rule forwarded from the PermissionRequest hook so the
/// capsule can offer an "Always allow" button. Mirrors the shape Claude Code
/// expects inside `updatedPermissions.rules[]`.
struct PermissionRuleSuggestion: Equatable, Sendable {
    let toolName: String    // e.g. "Bash"
    let ruleContent: String // e.g. "glab api *"
}

/// How a Stop reminder accepts a user reply. Drives both UI rendering
/// (which control to show) and `IslandStateManager.pushEvent` decision
/// guard logic (any non-nil mode means a hook is long-polling).
///
/// `quickReplies` is Phase 1 of #20 (#29) — yes/no buttons.
/// `freeformText` is Phase 2 of #20 (#36) — single-line text input,
/// gated by `enableInlineReply` UserDefault on the app side and
/// `CC_ISLAND_INLINE_REPLY=1` on the hook side.
enum ReplyMode: Equatable {
    case quickReplies([String])
    case freeformText
}

struct IslandEvent: Identifiable {
    let id: UUID
    let icon: String
    let title: String
    let subtitle: String
    let style: EventStyle
    let duration: TimeInterval
    let detail: String?
    let progress: Double?
    let persistent: Bool  // if true, won't auto-dismiss
    let project: String?  // small project name label
    let source: String?   // "claude" / "copilot" / "codex" — drives color
    let suggestedRule: PermissionRuleSuggestion?
    /// How this event accepts a user reply. Non-nil means a hook is
    /// long-polling on `/response` and the UI must render the matching
    /// control. See `ReplyMode` for the shapes; nil = no reply UI.
    let replyMode: ReplyMode?

    /// Subagent identifier from the hook payload (`agent_id`). Nil for
    /// main sessions. Used together with `project` to scope same-session
    /// detection — see `IslandStateManager.pushEvent` (#31 follow-up).
    let agentID: String?

    /// Claude Code's session UUID from the hook payload, when available.
    /// Lets us tell two main sessions in the same project apart for the
    /// same purpose as `agentID`.
    let sessionID: String?

    /// Color signaling event source. Falls back to a deterministic
    /// project-name hash when the source isn't known, so legacy callers
    /// (e.g. plain HTTP POST without source) still get visual variety.
    var projectColor: Color? {
        if let source, let color = Self.sourceColor(source) {
            return color
        }
        guard let project, !project.isEmpty else { return nil }
        let hash = project.utf8.reduce(0) { ($0 &+ UInt32($1)) &* 31 }
        let palette: [Color] = [
            Color(red: 0.85, green: 0.65, blue: 0.45), // warm orange
            Color(red: 0.55, green: 0.75, blue: 1.0),  // sky blue
            Color(red: 0.65, green: 0.9,  blue: 0.65), // mint green
            Color(red: 0.9,  green: 0.6,  blue: 0.9),  // lavender
            Color(red: 1.0,  green: 0.8,  blue: 0.4),  // gold
            Color(red: 0.5,  green: 0.85, blue: 0.85), // teal
            Color(red: 1.0,  green: 0.6,  blue: 0.6),  // coral
            Color(red: 0.7,  green: 0.7,  blue: 1.0),  // periwinkle
        ]
        return palette[Int(hash) % palette.count]
    }

    static func sourceColor(_ source: String) -> Color? {
        let key: String
        let fallback: String
        switch source.lowercased() {
        case "claude":  key = claudeColorHexKey;  fallback = defaultClaudeColorHex
        case "copilot": key = copilotColorHexKey; fallback = defaultCopilotColorHex
        case "codex":   key = codexColorHexKey;   fallback = defaultCodexColorHex
        default: return nil
        }
        let hex = dynamicIslandUserDefaults.string(forKey: key) ?? fallback
        let rgb = parseHexColor(hex) ?? parseHexColor(fallback) ?? RGB(r: 1, g: 1, b: 1)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    init(
        id: UUID = UUID(),
        icon: String = "",
        title: String,
        subtitle: String = "",
        style: EventStyle = .info,
        duration: TimeInterval = 4.0,
        detail: String? = nil,
        progress: Double? = nil,
        persistent: Bool = false,
        project: String? = nil,
        source: String? = nil,
        suggestedRule: PermissionRuleSuggestion? = nil,
        replyMode: ReplyMode? = nil,
        agentID: String? = nil,
        sessionID: String? = nil
    ) {
        self.id = id
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.duration = duration
        self.detail = detail
        self.progress = progress
        self.persistent = persistent
        self.project = project
        self.source = source
        self.suggestedRule = suggestedRule
        self.replyMode = replyMode
        self.agentID = agentID
        self.sessionID = sessionID
    }
}

enum EventStyle: String, Codable {
    case info
    case success
    case warning
    case error
    case claude // Claude Code specific
    case action // Needs user attention — persistent, pulsing, with buttons
    case reminder // Needs attention — pulsing, but no buttons

    var isPulsing: Bool { self == .action || self == .reminder }

    var color: Color {
        switch self {
        case .info: return .white
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .claude: return Color(red: 0.85, green: 0.65, blue: 0.45)
        case .action: return Color(red: 0.4, green: 0.7, blue: 1.0) // bright blue
        case .reminder: return Color(red: 0.4, green: 0.7, blue: 1.0)
        }
    }

    var glowColor: Color {
        switch self {
        case .info: return .white.opacity(0.3)
        case .success: return .green.opacity(0.4)
        case .warning: return .orange.opacity(0.4)
        case .error: return .red.opacity(0.4)
        case .claude: return Color(red: 0.85, green: 0.65, blue: 0.45).opacity(0.4)
        case .action: return Color(red: 0.4, green: 0.7, blue: 1.0).opacity(0.6)
        case .reminder: return Color(red: 0.4, green: 0.7, blue: 1.0).opacity(0.6)
        }
    }
}

// MARK: - Session Channels

/// Tracks activity for one concurrent agent (main session or subagent).
/// The expanded view renders a row per active channel so you can see what
/// multiple subagents are doing in parallel without them overwriting each
/// other in the compact ear.
struct SessionChannel: Identifiable {
    let id: String            // "main" for parent session; agent_id for subagents
    let agentType: String?    // nil for main
    let project: String?      // cwd basename
    var lastTitle: String
    var lastSubtitle: String
    var updatedAt: Date

    var isMain: Bool { id == "main" }

    var displayLabel: String {
        if isMain { return project ?? "main" }
        return "↳ \(agentType ?? "agent")"
    }

    /// Deterministic color from the channel id so the same subagent keeps
    /// its color across events within a run.
    var color: Color {
        let hash = id.utf8.reduce(0) { ($0 &+ UInt32($1)) &* 31 }
        let palette: [Color] = [
            Color(red: 0.85, green: 0.65, blue: 0.45),
            Color(red: 0.55, green: 0.75, blue: 1.0),
            Color(red: 0.65, green: 0.9,  blue: 0.65),
            Color(red: 0.9,  green: 0.6,  blue: 0.9),
            Color(red: 1.0,  green: 0.8,  blue: 0.4),
            Color(red: 0.5,  green: 0.85, blue: 0.85),
            Color(red: 1.0,  green: 0.6,  blue: 0.6),
            Color(red: 0.7,  green: 0.7,  blue: 1.0),
        ]
        return palette[Int(hash) % palette.count]
    }
}

// MARK: - Display Mode

/// One row in `IslandStateManager.recentEvents` — the audit trail
/// surfaced by Settings → Diagnostics. Captured at the top of
/// `pushEvent` so the buffer includes events that were dropped by
/// the dispatch logic, not just ones the user saw.
struct RecentEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let title: String
    let style: EventStyle
    let source: String?
    let disposition: EventDisposition
}

enum IslandMode: Equatable {
    case compact
    case expanded
    case hidden

    /// Window size — compact hugs the notch, expanded drops below it.
    /// `sessionRows` bumps the expanded height to fit the session tree;
    /// `detailLines` bumps it to fit a multi-line diff detail block.
    func size(hasNotch: Bool, sessionRows: Int = 0, detailLines: Int = 0) -> CGSize {
        let treeExtra: CGFloat = sessionRows >= 2 ? CGFloat(sessionRows) * 18 + 12 : 0
        // Base 130 already reserves space for ~3 detail lines; only pay more when
        // the diff is taller than that.
        let detailExtra: CGFloat = detailLines > 3 ? CGFloat(detailLines - 3) * 14 : 0
        if hasNotch {
            let w = IslandPanel.earWidth * 2 + IslandPanel.notchWidth
            switch self {
            case .compact: return CGSize(width: w, height: IslandPanel.notchHeight + 30)
            case .expanded: return CGSize(width: w, height: IslandPanel.notchHeight + 130 + treeExtra + detailExtra)
            case .hidden: return CGSize(width: w, height: IslandPanel.notchHeight + 30)
            }
        } else {
            // Sizes include a transparent margin around the pill so the
            // drop shadow / pulse border can render without clipping at
            // the window edge, and so clicks fall through beside the pill.
            switch self {
            case .compact: return CGSize(width: 260, height: 68)
            case .expanded: return CGSize(width: 420, height: 210 + treeExtra + detailExtra)
            case .hidden: return CGSize(width: 260, height: 68)
            }
        }
    }
}

// MARK: - State Manager

class IslandStateManager: ObservableObject {
    @Published var mode: IslandMode = .hidden
    @Published var currentEvent: IslandEvent?
    @Published var isHovered = false
    @Published var isThinking = false
    @Published var thinkingSource: String?

    /// Whether the panel's current screen has a camera notch. Published so the
    /// SwiftUI view tree re-renders when the panel relocates across screens
    /// — `panel.screen` is a Cocoa property SwiftUI can't observe directly.
    @Published var hasNotch: Bool = false

    /// Live view of main + subagent channels, sorted with main first
    @Published var activeSessions: [SessionChannel] = []

    /// Pending `.action` events queued behind the current one. A new `.action`
    /// arriving while another is awaiting a decision would otherwise overwrite
    /// the Allow/Deny UI and let the older hook's `/response` long-poll time
    /// out silently. FIFO — drained one-at-a-time by `dismiss()`.
    @Published private(set) var pendingActions: [IslandEvent] = []

    /// Flips to `true` when the current event's hook-side long-poll has
    /// timed out, so the UI can disable buttons and show a "reply window
    /// expired" hint instead of silently no-op'ing on a late click (#31).
    /// Reset on every `showEvent`.
    @Published private(set) var currentEventExpired: Bool = false
    private var expirationTimer: Timer?

    /// Ring buffer of the last 20 events `pushEvent` was asked to handle,
    /// regardless of disposition. Drives the Diagnostics tab so the user
    /// can answer "why didn't this event show up?" by scrolling recent
    /// attempts and seeing whether they were dropped, queued, or merged.
    @Published private(set) var recentEvents: [RecentEvent] = []
    private let recentEventsLimit = 20

    /// Reference to server for sending permission responses
    weak var server: LocalServer?

    /// Set once by `AppDelegate` after panel creation. Allows event
    /// arrivals to nudge the panel to the cursor's current screen
    /// without the state manager having to know what a screen is.
    weak var panel: IslandPanel?

    private var eventQueue: [IslandEvent] = []
    private var dismissTimer: Timer?
    private var isProcessing = false
    private var sessionSweepTimer: Timer?

    /// Sessions idle longer than this are auto-expired (handles missed Stop hooks)
    private let sessionIdleTimeout: TimeInterval = 90.0

    func pushEvent(_ event: IslandEvent) {
        DispatchQueue.main.async {
            // Ensure the panel is on the cursor's current screen before
            // we show the new event. No-op if already there.
            self.panel?.relocateToCursorScreen()

            // Decision logic (progress merge, decision-guard queueing,
            // expired-release, same-session takeover) lives in a pure
            // helper so it's unit-testable. See `EventDisposition`.
            let disposition = decideEventDisposition(
                current: self.currentEvent?.dispositionSnapshot,
                currentExpired: self.currentEventExpired,
                incoming: event.dispositionSnapshot
            )
            self.recordRecentEvent(event, disposition: disposition)
            switch disposition {
            case .mergeProgress:
                self.mergeProgress(into: event)
            case .queueAsAction:
                self.pendingActions.append(event)
            case .dropTransient:
                return
            case .showImmediately:
                self.showEvent(event)
            }
        }
    }

    /// Append to the bounded `recentEvents` ring buffer that powers
    /// the Diagnostics tab. Called for every `pushEvent` attempt
    /// (including dropped ones) so the user can audit dispatch
    /// outcomes.
    private func recordRecentEvent(_ event: IslandEvent, disposition: EventDisposition) {
        let entry = RecentEvent(
            timestamp: Date(),
            title: event.title,
            style: event.style,
            source: event.source,
            disposition: disposition
        )
        recentEvents.append(entry)
        if recentEvents.count > recentEventsLimit {
            recentEvents.removeFirst(recentEvents.count - recentEventsLimit)
        }
    }

    /// Same-title progress update: swap the event in place without
    /// re-animating entry or touching mode. Preserves the user's
    /// expanded / compact choice across rapid progress ticks.
    private func mergeProgress(into event: IslandEvent) {
        guard let current = self.currentEvent else { return }
        let merged = IslandEvent(
            id: current.id,
            icon: event.icon,
            title: event.title,
            subtitle: event.subtitle,
            style: event.style,
            duration: event.duration,
            detail: event.detail,
            progress: event.progress,
            persistent: event.persistent,
            project: event.project,
            source: event.source,
            suggestedRule: event.suggestedRule
        )
        self.currentEvent = merged
        if !event.persistent {
            self.dismissTimer?.invalidate()
            self.dismissTimer = Timer.scheduledTimer(withTimeInterval: event.duration, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, !self.isHovered else { return }
                    self.dismiss()
                }
            }
        }
    }

    /// Actually swap `currentEvent` and drive the dismiss timer. Assumes
    /// caller has already cleared any action guard.
    private func showEvent(_ event: IslandEvent) {
        eventQueue.removeAll()
        dismissTimer?.invalidate()
        isProcessing = true

        // Action events and quick-reply reminders open expanded so the
        // user can see the decision buttons immediately. Other events
        // start compact and grow if the user clicks.
        let needsExpanded = event.style == .action || event.replyMode != nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            currentEvent = event
            mode = needsExpanded ? .expanded : .compact
        }

        // Mirror the hook's long-poll horizon so the UI knows when a click
        // would arrive too late to matter. Disabling the buttons + showing
        // an "expired" hint is friendlier than a silent no-op (#31).
        // After a brief read window the pill auto-dismisses so it doesn't
        // turn into a permanent ghost — the queue guard also releases
        // (see `pushEvent`) so a new event can take over before then.
        currentEventExpired = false
        expirationTimer?.invalidate()
        if let timeout = expirationTimeout(for: event) {
            expirationTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.currentEvent?.id == event.id else { return }
                    self.currentEventExpired = true
                    // Auto-dismiss after a short read window so the slot
                    // doesn't stay locked.
                    Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                        DispatchQueue.main.async {
                            guard let self, self.currentEvent?.id == event.id else { return }
                            self.dismiss()
                        }
                    }
                }
            }
        }

        if !event.persistent {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: event.duration, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, !self.isHovered else { return }
                    self.dismiss()
                }
            }
        }
    }

    /// How long until the hook on the other end gives up waiting for a
    /// reply. Mirrors the hard-coded 25 s in `LocalServer.handleResponsePoll`
    /// for `.action`, and `IslandHookCore.StopReplyTimeoutSeconds` for the
    /// quick-reply path. `nil` for events with no decision affordance.
    private func expirationTimeout(for event: IslandEvent) -> TimeInterval? {
        if event.style == .action { return 25 }
        if event.replyMode != nil { return StopReplyTimeoutSeconds }
        return nil
    }

    func expand() {
        guard currentEvent != nil else { return }
        dismissTimer?.invalidate()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            mode = .expanded
        }
    }

    func collapse() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            mode = .compact
        }
        // Restart dismiss timer
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        expirationTimer?.invalidate()
        currentEventExpired = false

        // Drain the queued-action backlog before hiding — the next pending
        // action surfaces here rather than waiting for an external event.
        if !pendingActions.isEmpty {
            let next = pendingActions.removeFirst()
            showEvent(next)
            return
        }

        isProcessing = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            mode = .hidden
            currentEvent = nil
        }
    }

    func startThinking(source: String? = nil) {
        DispatchQueue.main.async {
            self.thinkingSource = source
            withAnimation(.easeInOut(duration: 0.6)) {
                self.isThinking = true
            }
        }
    }

    func stopThinking() {
        DispatchQueue.main.async {
            // Keep thinkingSource so the fade-out renders with the same tint
            // as the fade-in — next startThinking overwrites it.
            withAnimation(.easeInOut(duration: 0.8)) {
                self.isThinking = false
            }
        }
    }

    // MARK: - Session tracking

    /// Update (or create) a channel. Call on every event routed to a specific
    /// agent or main session.
    func updateSession(id: String, agentType: String?, project: String?, title: String, subtitle: String) {
        DispatchQueue.main.async {
            let channel = SessionChannel(
                id: id,
                agentType: agentType,
                project: project,
                lastTitle: title,
                lastSubtitle: subtitle,
                updatedAt: Date()
            )
            if let idx = self.activeSessions.firstIndex(where: { $0.id == id }) {
                self.activeSessions[idx] = channel
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.activeSessions.append(channel)
                    self.sortSessions()
                }
            }
            self.ensureSessionSweep()
        }
    }

    /// Close a subagent channel explicitly (from SubagentStop hook)
    func removeSession(id: String) {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                self.activeSessions.removeAll { $0.id == id }
            }
        }
    }

    private func sortSessions() {
        activeSessions.sort { a, b in
            if a.isMain != b.isMain { return a.isMain }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Periodically evict sessions that stopped pinging (missed Stop hook).
    /// Main session stays forever — it's the reference point.
    private func ensureSessionSweep() {
        guard sessionSweepTimer == nil else { return }
        sessionSweepTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let cutoff = Date().addingTimeInterval(-self.sessionIdleTimeout)
                let before = self.activeSessions.count
                self.activeSessions.removeAll { !$0.isMain && $0.updatedAt < cutoff }
                if self.activeSessions.count != before {
                    self.sortSessions()
                }
                if self.activeSessions.filter({ !$0.isMain }).isEmpty {
                    self.sessionSweepTimer?.invalidate()
                    self.sessionSweepTimer = nil
                }
            }
        }
    }
}

// MARK: - Disposition snapshot bridge

extension EventStyle {
    /// Map the full SwiftUI-coupled `EventStyle` enum to the coarse
    /// shape `EventDisposition` cares about: action, reminder, or
    /// other (transient).
    var dispositionShape: EventStyleShape {
        switch self {
        case .action: return .action
        case .reminder: return .reminder
        default: return .other
        }
    }
}

extension IslandEvent {
    /// Project the fields `decideEventDisposition` reads into a pure
    /// `EventSnapshot` that lives in `DynamicIslandCore`. Lets the
    /// dispatch logic stay testable without coupling to SwiftUI.
    var dispositionSnapshot: EventSnapshot {
        EventSnapshot(
            title: title,
            style: style.dispositionShape,
            hasReplyMode: replyMode != nil,
            hasProgress: progress != nil,
            sessionID: sessionID,
            agentID: agentID,
            project: project
        )
    }
}
