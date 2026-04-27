import SwiftUI

// MARK: - Root View

struct IslandRootView: View {
    @ObservedObject var stateManager: IslandStateManager
    weak var panel: IslandPanel?

    private var hasNotch: Bool { stateManager.hasNotch }

    var body: some View {
        VStack(spacing: 0) {
            if hasNotch {
                notchLayout
            } else {
                fallbackLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: stateManager.mode) { _ in
            updatePanelSize()
        }
        .onChange(of: stateManager.activeSessions.count) { _ in
            updatePanelSize()
        }
        .onChange(of: stateManager.currentEvent?.id) { _ in
            updatePanelSize()
        }
        .onChange(of: stateManager.isThinking) { _ in
            updatePanelSize()
        }
        .onHover { hovering in
            stateManager.isHovered = hovering
        }
    }

    private func updatePanelSize() {
        let rows = stateManager.activeSessions.count
        let detailLines = stateManager.currentEvent?.detail
            .map { min($0.split(separator: "\n").count, 10) } ?? 0
        let size = IslandPanel.adjustedSize(
            mode: stateManager.mode,
            event: stateManager.currentEvent,
            hasNotch: hasNotch,
            sessionRows: rows,
            detailLines: detailLines
        )
        panel?.updateSize(to: size)
    }

    // MARK: - Notch Layout (ears + expand below)

    @ViewBuilder
    private var notchLayout: some View {
        let event = stateManager.currentEvent
        let isVisible = stateManager.mode != .hidden && event != nil

        // Left ear: trailing edge flush with notch left edge
        // Right ear: leading edge flush with notch right edge
        // Use two half-width containers to guarantee the notch gap stays centered
        HStack(spacing: IslandPanel.notchWidth) {
            LeftEarView(
                event: event,
                isVisible: isVisible,
                stateManager: stateManager
            )
            .frame(width: IslandPanel.earWidth, height: IslandPanel.notchHeight)
            .offset(x: isVisible ? 0 : IslandPanel.earWidth)
            .opacity(isVisible ? 1 : 0)

            RightEarView(
                event: event,
                isVisible: isVisible,
                stateManager: stateManager
            )
            .frame(width: IslandPanel.earWidth, height: IslandPanel.notchHeight)
            .offset(x: isVisible ? 0 : -IslandPanel.earWidth)
            .opacity(isVisible ? 1 : 0)
        }
        .frame(height: IslandPanel.notchHeight)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: isVisible)
        .clipped()

        // Expanded content below the notch
        if stateManager.mode == .expanded, let event {
            ExpandedContentView(event: event, stateManager: stateManager)
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 4)
        }
    }

    // MARK: - Fallback (no notch)

    @ViewBuilder
    private var fallbackLayout: some View {
        ZStack {
            if let event = stateManager.currentEvent, stateManager.mode == .expanded {
                ExpandedPillView(event: event, stateManager: stateManager)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            } else if let event = stateManager.currentEvent, stateManager.mode == .compact {
                CompactPillView(event: event, stateManager: stateManager)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else if stateManager.isThinking {
                // Capsule equivalent of the notch's `PulseWindow`. Only shown
                // when no event is in flight; an arriving event takes over
                // the slot, the pill returns once the event dismisses if
                // `isThinking` is still true.
                ThinkingPillView(source: stateManager.thinkingSource)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: stateManager.isThinking)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: stateManager.mode)
    }
}

// MARK: - Ear Shapes (with concave inner corner to hug notch radius)

/// Left ear: top-left square (flush with screen), bottom-left convex rounded,
/// bottom-right has a concave cutout that wraps around the notch's rounded corner.
struct LeftEarShape: Shape {
    let outerRadius: CGFloat  // bottom-left convex corner
    let notchRadius: CGFloat  // concave inner corner matching notch

    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Start top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top edge to top-right
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Right edge down, then concave curve hugging notch corner
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - notchRadius))
        // Concave arc: curves inward (toward left) to match notch's convex corner
        p.addArc(
            center: CGPoint(x: rect.maxX + notchRadius, y: rect.maxY - notchRadius),
            radius: notchRadius,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )
        // Bottom edge to bottom-left corner
        p.addLine(to: CGPoint(x: rect.minX + outerRadius, y: rect.maxY))
        // Bottom-left convex corner
        p.addArc(
            center: CGPoint(x: rect.minX + outerRadius, y: rect.maxY - outerRadius),
            radius: outerRadius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

/// Right ear: mirror of LeftEarShape
struct RightEarShape: Shape {
    let outerRadius: CGFloat
    let notchRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Start top-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Top edge to top-left
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left edge down, then concave curve hugging notch corner
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - notchRadius))
        // Concave arc: curves inward (toward right) to match notch's convex corner
        p.addArc(
            center: CGPoint(x: rect.minX - notchRadius, y: rect.maxY - notchRadius),
            radius: notchRadius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        // Bottom edge to bottom-right corner
        p.addLine(to: CGPoint(x: rect.maxX - outerRadius, y: rect.maxY))
        // Bottom-right convex corner
        p.addArc(
            center: CGPoint(x: rect.maxX - outerRadius, y: rect.maxY - outerRadius),
            radius: outerRadius,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - Left Ear (icon + title)

struct LeftEarView: View {
    let event: IslandEvent?
    let isVisible: Bool
    @ObservedObject var stateManager: IslandStateManager
    @State private var appeared = false
    @State private var actionPulse = false

    private var isPulsing: Bool { event?.style == .action || event?.style == .reminder }
    private var isAction: Bool { event?.style == .action }

    var body: some View {
        ZStack {
            LeftEarShape(outerRadius: 16, notchRadius: 10)
                .fill(.black)

            // Source-color stripe down the leading (outer) edge.
            // Clipped to the ear shape so it follows the rounded outer corner.
            if let color = event?.projectColor, isVisible {
                Rectangle()
                    .fill(color)
                    .frame(width: 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mask(LeftEarShape(outerRadius: 16, notchRadius: 10))
            }

            // Pulsing border for action/reminder events — uses source color when known
            if isPulsing {
                let pulseColor = event?.projectColor ?? event!.style.color
                LeftEarShape(outerRadius: 16, notchRadius: 10)
                    .stroke(pulseColor.opacity(actionPulse ? 0.8 : 0.2), lineWidth: 1.5)
            }

            if isVisible, let event {
                // EXPERIMENT: flip title/project on notch ear.
                // Primary = project (when present), secondary = action.
                // Source is already signalled by the outer edge stripe,
                // so no separate dot inside the text.
                let hasProject = (event.project?.isEmpty == false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hasProject ? (event.project ?? "") : event.title)
                        .font(.system(size: hasProject ? 11 : 12, weight: isPulsing ? .semibold : .medium))
                        .foregroundColor(isPulsing ? event.style.color : .white)
                        .lineLimit(1)

                    if hasProject {
                        Text(event.title)
                            .font(.system(size: 8, weight: .regular))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .shadow(
            color: isPulsing
                ? (event?.projectColor ?? event?.style.color ?? .clear).opacity(actionPulse ? 0.6 : 0.1)
                : .clear,
            radius: 8
        )
        .onTapGesture {
            if isPulsing { stateManager.dismiss() } else { stateManager.expand() }
        }
        .onChange(of: isVisible) { vis in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.05)) {
                appeared = vis
            }
            if vis && isPulsing {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    actionPulse = true
                }
            } else {
                actionPulse = false
            }
        }
    }
}

// MARK: - Right Ear (subtitle / progress)

struct RightEarView: View {
    let event: IslandEvent?
    let isVisible: Bool
    @ObservedObject var stateManager: IslandStateManager
    @State private var actionPulse = false

    private var isPulsing: Bool { event?.style == .action || event?.style == .reminder }
    private var isAction: Bool { event?.style == .action }

    var body: some View {
        ZStack {
            RightEarShape(outerRadius: 16, notchRadius: 10)
                .fill(.black)

            // Source-color stripe down the trailing (outer) edge
            if let color = event?.projectColor, isVisible {
                Rectangle()
                    .fill(color)
                    .frame(width: 4)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .mask(RightEarShape(outerRadius: 16, notchRadius: 10))
            }

            if isPulsing {
                let pulseColor = event?.projectColor ?? event!.style.color
                RightEarShape(outerRadius: 16, notchRadius: 10)
                    .stroke(pulseColor.opacity(actionPulse ? 0.8 : 0.2), lineWidth: 1.5)
            }

            if isVisible, let event {
                HStack(spacing: 6) {
                    if let progress = event.progress {
                        ProgressRing(progress: progress, color: event.style.color)
                            .frame(width: 14, height: 14)
                    }

                    if !event.subtitle.isEmpty {
                        Text(event.subtitle)
                            .font(.system(size: 12, weight: isPulsing ? .semibold : .regular))
                            .foregroundColor(isPulsing ? event.style.color : event.style.color.opacity(0.9))
                            .lineLimit(1)
                    } else {
                        Circle()
                            .fill(event.style.color)
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .shadow(
            color: isPulsing
                ? (event?.projectColor ?? event?.style.color ?? .clear).opacity(actionPulse ? 0.6 : 0.1)
                : .clear,
            radius: 8
        )
        .onTapGesture {
            if isPulsing { stateManager.dismiss() } else { stateManager.expand() }
        }
        .onChange(of: isVisible) { vis in
            if vis && isPulsing {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    actionPulse = true
                }
            } else {
                actionPulse = false
            }
        }
    }
}

// MARK: - Expanded Content (drops below notch)

struct ExpandedContentView: View {
    let event: IslandEvent
    @ObservedObject var stateManager: IslandStateManager
    // TODO(settings): expose enableInlineReply in #11 settings pane.
    // Drives whether `.freeformText` events render an `InlineReplyField`.
    // Default false → no behavioural change for users who haven't opted in.
    @AppStorage(enableInlineReplyKey, store: dynamicIslandUserDefaults)
    private var inlineReplyEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    if !event.subtitle.isEmpty {
                        Text(event.subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                }

                Spacer()

                Button(action: { stateManager.dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }

            // Detail — renders as a colored diff when lines start with "+ " / "- ",
            // otherwise falls back to plain monospaced text
            if let detail = event.detail {
                // Decision events (Allow/Deny or quick reply) need the full
                // context to choose — let the detail scroll. Observational
                // events keep notch's truncated default for visual density.
                let needsFullContext = event.style == .action || event.replyMode != nil
                DiffDetailView(text: detail, scrollable: needsFullContext)
            }

            if event.style == .action {
                PermissionActionButtons(
                    stateManager: stateManager,
                    suggestedRule: event.suggestedRule,
                    eventID: event.id
                )
            }

            switch event.replyMode {
            case .quickReplies(let labels):
                QuickReplyButtons(stateManager: stateManager, labels: labels, eventID: event.id)
            case .freeformText:
                if inlineReplyEnabled {
                    InlineReplyField(stateManager: stateManager, eventID: event.id)
                }
            case .none:
                EmptyView()
            }

            if let progress = event.progress {
                LinearProgressBar(progress: progress, color: event.style.color)
            }

            // Active session tree — main + subagents
            if stateManager.activeSessions.count >= 2 {
                SessionTreeView(sessions: stateManager.activeSessions)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: IslandPanel.earWidth * 2 + IslandPanel.notchWidth)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(event.style.glowColor, lineWidth: 0.5)
                )
                .shadow(color: event.style.glowColor, radius: 10, y: 4)
        )
        .onTapGesture {
            // Don't collapse while the user is mid-decision: action events
            // (Allow/Deny) and reminders with quick-reply buttons. Collapsing
            // sets a 2 s dismiss timer that strands the long-polling hook.
            if event.style == .action || event.replyMode != nil { return }
            stateManager.collapse()
        }
    }
}

// MARK: - Fallback Compact Pill (no notch)

struct CompactPillView: View {
    let event: IslandEvent
    @ObservedObject var stateManager: IslandStateManager
    @State private var appeared = false

    /// Promote `event.project` to the primary title slot whenever we have
    /// one — multi-session users read "which session" before "what action".
    /// Falls back to `event.title` for bare `/event` POSTs with no project.
    private var hasProject: Bool {
        guard let project = event.project else { return false }
        return !project.isEmpty && project != event.title
    }

    private var primaryTitle: String { hasProject ? event.project! : event.title }

    private var actionChipText: String? { hasProject ? event.title : nil }

    var body: some View {
        HStack(spacing: 8) {
            // Source dot — the capsule's analogue to the ear's outer stripe.
            Circle()
                .fill(event.projectColor ?? event.style.color)
                .frame(width: 6, height: 6)

            if !event.icon.isEmpty {
                Text(event.icon)
                    .font(.system(size: 15))
                    .scaleEffect(appeared ? 1.0 : 0.5)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.1), value: appeared)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(primaryTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let chip = actionChipText {
                        Text(chip)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(event.style.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(event.style.color.opacity(0.18))
                            )
                    }
                }

                if !event.subtitle.isEmpty {
                    Text(event.subtitle)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if let progress = event.progress {
                ProgressRing(progress: progress, color: event.style.color)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(height: event.subtitle.isEmpty ? 38 : 44)
        .background(
            Capsule()
                .fill(.black)
                .overlay(Capsule().strokeBorder(event.style.glowColor, lineWidth: 1))
                .shadow(color: event.style.glowColor, radius: 8, x: 0, y: 2)
        )
        .onTapGesture { stateManager.expand() }
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
    }
}

// MARK: - Fallback Expanded Pill (no notch)

struct ExpandedPillView: View {
    let event: IslandEvent
    @ObservedObject var stateManager: IslandStateManager
    @State private var actionPulse = false
    // TODO(settings): expose enableInlineReply in #11 settings pane.
    @AppStorage(enableInlineReplyKey, store: dynamicIslandUserDefaults)
    private var inlineReplyEnabled = false

    private var isPulsing: Bool { event.style.isPulsing }

    private var hasProject: Bool {
        guard let project = event.project else { return false }
        return !project.isEmpty && project != event.title
    }

    private var primaryTitle: String { hasProject ? event.project! : event.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if !event.icon.isEmpty {
                    Text(event.icon).font(.system(size: 22))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(primaryTitle)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        if hasProject {
                            Text(event.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(event.style.color)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(event.style.color.opacity(0.18))
                                )
                        }
                    }

                    if !event.subtitle.isEmpty {
                        Text(event.subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                }
                Spacer()
                if stateManager.pendingActions.count > 0 {
                    PendingActionDots(count: stateManager.pendingActions.count)
                }
                Button(action: { stateManager.dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }

            if let detail = event.detail {
                DiffDetailView(text: detail, scrollable: true)
            }

            if event.style == .action {
                PermissionActionButtons(
                    stateManager: stateManager,
                    suggestedRule: event.suggestedRule,
                    eventID: event.id
                )
            }

            switch event.replyMode {
            case .quickReplies(let labels):
                QuickReplyButtons(stateManager: stateManager, labels: labels, eventID: event.id)
            case .freeformText:
                if inlineReplyEnabled {
                    InlineReplyField(stateManager: stateManager, eventID: event.id)
                }
            case .none:
                EmptyView()
            }

            if let progress = event.progress {
                LinearProgressBar(progress: progress, color: event.style.color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(
                            isPulsing
                                ? (event.projectColor ?? event.style.color).opacity(actionPulse ? 0.85 : 0.25)
                                : event.style.glowColor,
                            lineWidth: isPulsing ? 1.5 : 1
                        )
                )
                .shadow(
                    color: isPulsing
                        ? (event.projectColor ?? event.style.color).opacity(actionPulse ? 0.55 : 0.15)
                        : event.style.glowColor,
                    radius: 12, y: 4
                )
        )
        .onTapGesture {
            // Don't collapse while the user is mid-decision: action events
            // (Allow/Deny) and reminders with quick-reply buttons. Collapsing
            // sets a 2 s dismiss timer that strands the long-polling hook.
            if event.style == .action || event.replyMode != nil { return }
            stateManager.collapse()
        }
        .onAppear { updateActionPulse() }
        .onChange(of: event.id) { _ in updateActionPulse() }
    }

    private func updateActionPulse() {
        if isPulsing {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                actionPulse = true
            }
        } else {
            actionPulse = false
        }
    }
}

// MARK: - Thinking Pulse

/// Root content of the separate pulse child window. Renders the pulse only
/// while `stateManager.isThinking` is true; the opacity transition matches
/// the previous in-panel behavior.
struct PulseRootView: View {
    @ObservedObject var stateManager: IslandStateManager

    var body: some View {
        ZStack {
            if stateManager.isThinking {
                ThinkingPulseView(source: stateManager.thinkingSource)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ThinkingPulseView: View {
    let source: String?
    @State private var phase: CGFloat = 0

    private static let fallbackColor = Color(red: 0.85, green: 0.65, blue: 0.45)

    private var tint: Color {
        source.flatMap { IslandEvent.sourceColor($0) } ?? Self.fallbackColor
    }

    var body: some View {
        // Glow bar right below the notch
        RoundedRectangle(cornerRadius: 20)
            .fill(tint.opacity(0.4 * pulseValue))
            .frame(width: IslandPanel.notchWidth - 20, height: 4)
            .shadow(color: tint.opacity(0.9 * pulseValue), radius: 14, y: 2)
            .shadow(color: tint.opacity(0.5 * pulseValue), radius: 6, y: 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private var pulseValue: CGFloat {
        // Smooth 0→1→0 breathing
        return 0.3 + 0.7 * phase
    }
}

// MARK: - Thinking Pill (fallback / capsule mode)

/// Three-dot breathing pill shown in fallback (non-notch) mode while the
/// caller is thinking but no event is currently on screen. Source-tinted
/// to match the active AI (Claude orange / Copilot violet / Codex green).
///
/// Notch mode uses `ThinkingPulseView` (a separate `PulseWindow`) for the
/// same job — capsule users had no equivalent visual after v1.6.1 hid
/// the pulse window in fallback mode, so they got zero feedback while
/// the AI was reasoning between tool events. This pill closes that gap.
///
/// Animation driven by `TimelineView(.animation)` so each frame
/// recomputes per-dot phase from wall-clock time. SwiftUI's implicit
/// animation only evaluates `body` at state endpoints and would miss
/// the triangle-wave peaks if we tried to derive phase from a `@State`
/// bounced 0↔1.
struct ThinkingPillView: View {
    let source: String?

    private static let fallbackColor = Color(red: 0.85, green: 0.65, blue: 0.45)
    private static let dotCount = 3
    private static let stagger: Double = 0.18  // seconds between dot peaks
    private static let cycle: Double = 1.4     // full cycle duration
    private let startDate = Date()

    private var tint: Color {
        source.flatMap { IslandEvent.sourceColor($0) } ?? Self.fallbackColor
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            HStack(spacing: 6) {
                ForEach(0..<Self.dotCount, id: \.self) { i in
                    dot(for: i, elapsed: elapsed)
                }
            }
            .padding(.horizontal, 14)
            .frame(width: 64, height: 26)
            .background(
                Capsule()
                    .fill(Color.black)
                    .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            )
        }
    }

    @ViewBuilder
    private func dot(for index: Int, elapsed: Double) -> some View {
        let p = triangleWave(time: elapsed, delay: Double(index) * Self.stagger)
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .opacity(0.3 + 0.7 * p)
            .scaleEffect(0.9 + 0.2 * p)
            .offset(y: -2 * p)
    }

    /// Triangle wave 0→1→0 over `cycle` seconds, offset by `delay`.
    private func triangleWave(time: Double, delay: Double) -> Double {
        let t = ((time + delay).truncatingRemainder(dividingBy: Self.cycle)) / Self.cycle
        return t < 0.5 ? t * 2 : (1 - t) * 2
    }
}

// MARK: - Diff Detail (colored + / - lines)

/// Renders `detail` line-by-line with diff coloring: lines starting with
/// "- " → red, "+ " → green, everything else → muted white. Non-diff
/// content renders as plain monospaced text.
struct DiffDetailView: View {
    let text: String
    /// When true, render all lines inside a vertical ScrollView capped at
    /// `maxVisibleHeight`. Default false preserves the existing truncated
    /// rendering used by the notch layout.
    var scrollable: Bool = false

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    private let maxVisibleHeight: CGFloat = 160

    var body: some View {
        Group {
            if scrollable {
                ScrollView(.vertical, showsIndicators: true) {
                    linesStack
                        .padding(8)
                }
                .frame(maxHeight: maxVisibleHeight)
            } else {
                truncatedStack
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
        )
    }

    private var linesStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineText(line)
            }
        }
    }

    private var truncatedStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.prefix(10).enumerated()), id: \.offset) { _, line in
                lineText(line)
            }
            if lines.count > 10 {
                Text("… +\(lines.count - 10) more")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    private func lineText(_ line: Substring) -> some View {
        Text(line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(color(for: line))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("- ") { return Color(red: 1.0, green: 0.55, blue: 0.55) }
        if line.hasPrefix("+ ") { return Color(red: 0.55, green: 0.95, blue: 0.65) }
        return .white.opacity(0.65)
    }
}

// MARK: - Session Tree (main + active subagents)

struct SessionTreeView: View {
    let sessions: [SessionChannel]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.bottom, 2)

            ForEach(sessions) { session in
                SessionRow(session: session)
            }
        }
    }
}

struct SessionRow: View {
    let session: SessionChannel

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var isFresh: Bool {
        Date().timeIntervalSince(session.updatedAt) < 3.0
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.color)
                .frame(width: 6, height: 6)
                .opacity(isFresh ? 1.0 : 0.45)

            Text(session.displayLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(isFresh ? 0.95 : 0.55))
                .lineLimit(1)

            Text(activityText)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.white.opacity(isFresh ? 0.7 : 0.35))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)
        }
    }

    private var activityText: String {
        if session.lastSubtitle.isEmpty { return session.lastTitle }
        return "\(session.lastTitle) · \(session.lastSubtitle)"
    }
}

// MARK: - Pending Action Dots

/// Hints that more `.action` events are queued behind the current one,
/// without a numeric badge. Up to three dots.
struct PendingActionDots: View {
    let count: Int
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(count, 3), id: \.self) { _ in
                Circle()
                    .fill(Color.white.opacity(pulse ? 0.85 : 0.45))
                    .frame(width: 4, height: 4)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Permission Action Buttons (shared by notch + capsule expanded)

struct PermissionActionButtons: View {
    @ObservedObject var stateManager: IslandStateManager
    let suggestedRule: PermissionRuleSuggestion?
    let eventID: UUID

    private var expired: Bool { stateManager.currentEventExpired }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: {
                    stateManager.server?.setResponse("allow", eventID: eventID)
                    stateManager.dismiss()
                }) {
                    Text("Allow")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(red: 0.2, green: 0.5, blue: 1.0))
                        )
                }
                .buttonStyle(.plain)
                .disabled(expired)

                Button(action: {
                    stateManager.server?.setResponse("deny", eventID: eventID)
                    stateManager.dismiss()
                }) {
                    Text("Deny")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .disabled(expired)
            }
            .opacity(expired ? 0.5 : 1)

            // "Always allow" — sends the rule back to Claude Code so the
            // pattern lands in `localSettings.permissions.allow` and future
            // matching invocations stop asking. Amber tint (not the Allow
            // blue) signals "this is a persistent preference" rather than a
            // primary yes/no action, and shrinks the tap target to reduce
            // mis-taps on the adjacent Allow button.
            if let rule = suggestedRule {
                Button(action: {
                    stateManager.server?.setResponse("allow", rule: rule, eventID: eventID)
                    stateManager.dismiss()
                }) {
                    HStack(spacing: 8) {
                        Spacer()
                        Text("🔓").font(.system(size: 11))
                        Text("Always allow")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.4))
                        Text(rule.ruleContent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.59).opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color(red: 1.0, green: 0.67, blue: 0.24).opacity(0.14))
                    )
                }
                .buttonStyle(.plain)
                .disabled(expired)
                .opacity(expired ? 0.5 : 1)
            }

            if expired {
                Text("Reply window expired — dismiss and re-trigger to respond.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

// MARK: - Quick Reply Buttons (shared by notch + capsule expanded)

/// Phase 1 of #20. Renders one button per `labels` entry; tap POSTs the
/// label as the response body to the long-polling Stop hook, which then
/// emits `decision:block + reason:<label>` to Claude. Layout and tinting
/// mirror `PermissionActionButtons` so the two buttons rows feel
/// consistent across action and reminder events.
///
/// Caller is expected to cap `labels` at 3 entries / 20 chars each
/// (enforced server-side in `LocalServer.processEvent` already).
struct QuickReplyButtons: View {
    @ObservedObject var stateManager: IslandStateManager
    let labels: [String]
    let eventID: UUID

    private var expired: Bool { stateManager.currentEventExpired }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                ForEach(labels, id: \.self) { label in
                    Button(action: {
                        stateManager.server?.setResponse(label, eventID: eventID)
                        stateManager.dismiss()
                    }) {
                        Text(label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.95))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(expired)
                }
            }
            .opacity(expired ? 0.5 : 1)

            if expired {
                Text("Reply window expired — dismiss and re-trigger to respond.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }
}

// MARK: - Inline Reply Field (#36, #20 Phase 2)

/// Single-line text input + Send for free-form Stop replies. Dumb
/// component — the parent decides whether to render it (gated on the
/// `enableInlineReply` UserDefault) and feeds the eventID. Submit
/// posts the typed string through the same `setResponse` channel
/// quick-reply buttons use; the hook emits
/// `decision: block + reason: <text>` so Claude treats it as the
/// next instruction.
struct InlineReplyField: View {
    @ObservedObject var stateManager: IslandStateManager
    let eventID: UUID
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Reply…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused($focused)
                .onSubmit(submit)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                )

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(
                        text.trimmingCharacters(in: .whitespaces).isEmpty
                            ? Color.white.opacity(0.3)
                            : Color(red: 0.4, green: 0.7, blue: 1.0)
                    )
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear {
            // Panel uses `.nonactivatingPanel` and is not key by default,
            // so the TextField stays visible but rejects keystrokes.
            // Promote the panel to key + focus the field together so the
            // first character lands without an extra click.
            stateManager.panel?.makeKey()
            focused = true
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        stateManager.server?.setResponse(trimmed, eventID: eventID)
        stateManager.dismiss()
    }
}

// MARK: - Linear Progress Bar (shared by notch + capsule expanded)

struct LinearProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: geo.size.width * progress, height: 4)
                    .animation(.easeOut(duration: 0.25), value: progress)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Progress Ring

struct ProgressRing: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: progress)
        }
    }
}
