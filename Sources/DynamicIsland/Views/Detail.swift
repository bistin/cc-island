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

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    /// True when the text looks like a unified diff (has at least one
    /// line starting with `+ ` — additions). Without this guard, plain
    /// markdown bullet lines (`- foo`) on a non-diff Stop reply detail
    /// would render bright red as if they were diff deletions.
    private var looksLikeDiff: Bool {
        lines.contains { $0.hasPrefix("+ ") }
    }

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
        guard looksLikeDiff else { return .white.opacity(0.65) }
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
