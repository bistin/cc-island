import Foundation
import SwiftUI

// MARK: - Event Model

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
        switch source.lowercased() {
        case "claude":  return Color(red: 0.85, green: 0.65, blue: 0.45) // warm orange
        case "copilot": return Color(red: 0.65, green: 0.50, blue: 0.95) // GitHub violet
        case "codex":   return Color(red: 0.30, green: 0.80, blue: 0.60) // OpenAI green
        default: return nil
        }
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
        source: String? = nil
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

    /// Live view of main + subagent channels, sorted with main first
    @Published var activeSessions: [SessionChannel] = []

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

            // In-place progress update: same title + both carry progress →
            // swap the event without re-animating entry or touching mode.
            // Preserves user's expanded/compact choice across updates.
            if let current = self.currentEvent,
               current.title == event.title,
               current.progress != nil,
               event.progress != nil {
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
                    project: event.project
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
                return
            }

            // Normal path: show the latest event immediately, replacing any queue
            self.eventQueue.removeAll()
            self.dismissTimer?.invalidate()
            self.isProcessing = true

            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                self.currentEvent = event
                self.mode = (event.style == .action) ? .expanded : .compact
            }

            if !event.persistent {
                self.dismissTimer = Timer.scheduledTimer(withTimeInterval: event.duration, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, !self.isHovered else { return }
                        self.dismiss()
                    }
                }
            }
        }
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
