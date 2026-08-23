import DynamicIslandCore
import SwiftUI

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

    private var lines: [Substring] { DiffLines.split(text) }
    private var kinds: [DiffLineKind] { DiffLines.kinds(of: text) }

    private let maxVisibleHeight: CGFloat = 160
    private let minVisibleHeight: CGFloat = 46

    var body: some View {
        Group {
            if scrollable {
                ScrollView(.vertical, showsIndicators: true) {
                    linesStack
                        .padding(8)
                }
                // A minimum as well as a maximum. A ScrollView with only a maximum does not clip
                // when the space runs out — it collapses to nothing, and a detail that vanishes
                // silently is worse than one that is cut short, because nothing on screen says
                // anything is missing.
                .frame(minHeight: minVisibleHeight, maxHeight: maxVisibleHeight)
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
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                lineText(line, kind: kind(at: index))
            }
        }
    }

    private var truncatedStack: some View {
        let shown = DiffLines.compact(text)
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(shown.lines.enumerated()), id: \.offset) { index, line in
                lineText(line, kind: kind(at: index))
            }
            if shown.hidden > 0 {
                Text("… +\(shown.hidden) more")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    /// The classification is made against the whole block, so a truncated view still colours its
    /// lines the way the full one would.
    private func kind(at index: Int) -> DiffLineKind {
        index < kinds.count ? kinds[index] : .plain
    }

    private func lineText(_ line: Substring, kind: DiffLineKind) -> some View {
        Text(line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Self.color(for: kind))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Colours only. Whether a line *is* an addition is `DiffLines`' business, and testable
    /// there; what red and green look like is this file's.
    private static func color(for kind: DiffLineKind) -> Color {
        switch kind {
        case .removed: return Color(red: 1.0, green: 0.55, blue: 0.55)
        case .added:   return Color(red: 0.55, green: 0.95, blue: 0.65)
        case .plain:   return .white.opacity(0.65)
        }
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
