import SwiftUI

// MARK: - Expanded Content (drops below notch)

struct ExpandedContentView: View {
    let event: IslandEvent
    @ObservedObject var stateManager: IslandStateManager
    // Settings panel binding (#41). Mirrors the toggle in `SettingsView`.
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
                    eventID: event.id,
                    tty: event.tty,
                    tmuxSocket: event.tmuxSocket
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
            stateManager.handleExpandedTap(for: event)
        }
    }
}
