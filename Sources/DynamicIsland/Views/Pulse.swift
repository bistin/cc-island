import SwiftUI

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
