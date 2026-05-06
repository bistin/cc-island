import SwiftUI

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
        .onTapGesture { stateManager.handleCompactTap() }
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
    }
}

// MARK: - Fallback Expanded Pill (no notch)

struct ExpandedPillView: View {
    let event: IslandEvent
    @ObservedObject var stateManager: IslandStateManager
    @State private var actionPulse = false
    // Settings panel binding (#41). Mirrors the toggle in `SettingsView`.
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
