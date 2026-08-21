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
            detailLines: detailLines,
            decisionRows: decisionRowCount(stateManager.currentEvent)
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

/// How many rows of controls sit under the detail. Allow/Deny brings its own jump-to-terminal row
/// with it, which is why an action counts as two rather than one — the row that was missing from
/// the height sum and cost the diff its space.
func decisionRowCount(_ event: IslandEvent?) -> Int {
    guard let event else { return 0 }
    if event.style == .action { return 2 }
    return event.replyMode == nil ? 0 : 1
}
