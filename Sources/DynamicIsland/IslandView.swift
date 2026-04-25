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
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: event.project != nil ? 11 : 12, weight: isPulsing ? .semibold : .medium))
                        .foregroundColor(isPulsing ? event.style.color : .white)
                        .lineLimit(1)

                    if let project = event.project {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(event.projectColor ?? .white.opacity(0.4))
                                .frame(width: 4, height: 4)
                            Text(project)
                                .font(.system(size: 8, weight: .regular))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }
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
                DiffDetailView(text: detail)
            }

            // Permission buttons for action events
            if event.style == .action {
                HStack(spacing: 12) {
                    Button(action: {
                        stateManager.server?.setResponse("allow")
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

                    Button(action: {
                        stateManager.server?.setResponse("deny")
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
                }
            }

            // Progress bar
            if let progress = event.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(event.style.color)
                            .frame(width: geo.size.width * progress, height: 4)
                            .animation(.easeOut(duration: 0.25), value: progress)
                    }
                }
                .frame(height: 4)
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
        .onTapGesture { stateManager.collapse() }
    }
}

// MARK: - Fallback Compact Pill (no notch)

struct CompactPillView: View {
    let event: IslandEvent
    @ObservedObject var stateManager: IslandStateManager
    @State private var appeared = false

    /// Project prefix joined to subtitle so the pill shows which concurrent
    /// session an event came from. The notch ear has an equivalent sublabel
    /// via `event.project`; the capsule can't spare a second line so we
    /// inline it.
    private var secondaryLine: String {
        let project = event.project ?? ""
        switch (project.isEmpty, event.subtitle.isEmpty) {
        case (true, true):   return ""
        case (true, false):  return event.subtitle
        case (false, true):  return project
        case (false, false): return "\(project) · \(event.subtitle)"
        }
    }

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
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if !secondaryLine.isEmpty {
                    Text(secondaryLine)
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
        .frame(height: secondaryLine.isEmpty ? 38 : 44)
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

    private var isPulsing: Bool { event.style.isPulsing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if !event.icon.isEmpty {
                    Text(event.icon).font(.system(size: 22))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
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

            if let detail = event.detail {
                DiffDetailView(text: detail, scrollable: true)
            }

            if event.style == .action {
                PermissionActionButtons(stateManager: stateManager)
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
            // Don't collapse on action — the user must pick Allow or Deny.
            if event.style == .action { return }
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

// MARK: - Permission Action Buttons (shared by notch + capsule expanded)

struct PermissionActionButtons: View {
    @ObservedObject var stateManager: IslandStateManager

    var body: some View {
        HStack(spacing: 12) {
            Button(action: {
                stateManager.server?.setResponse("allow")
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

            Button(action: {
                stateManager.server?.setResponse("deny")
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
        }
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
