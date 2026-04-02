import SwiftUI

// MARK: - Root View

struct IslandRootView: View {
    @ObservedObject var stateManager: IslandStateManager
    weak var panel: IslandPanel?

    private var hasNotch: Bool { panel?.hasNotch ?? false }

    var body: some View {
        VStack(spacing: 0) {
            if hasNotch {
                notchLayout
            } else {
                fallbackLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: stateManager.mode) { newMode in
            panel?.updateSize(to: newMode.size(hasNotch: hasNotch))
        }
        .onHover { hovering in
            stateManager.isHovered = hovering
        }
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
        if stateManager.mode != .hidden, let event = stateManager.currentEvent {
            switch stateManager.mode {
            case .compact:
                CompactPillView(event: event, stateManager: stateManager)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            case .expanded:
                ExpandedPillView(event: event, stateManager: stateManager)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            default:
                EmptyView()
            }
        }
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

    var body: some View {
        ZStack {
            LeftEarShape(outerRadius: 16, notchRadius: 10)
                .fill(.black)

            if isVisible, let event {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .padding(.trailing, 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .onTapGesture { stateManager.expand() }
        .onChange(of: isVisible) { vis in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.05)) {
                appeared = vis
            }
        }
    }
}

// MARK: - Right Ear (subtitle / progress)

struct RightEarView: View {
    let event: IslandEvent?
    let isVisible: Bool
    @ObservedObject var stateManager: IslandStateManager

    var body: some View {
        ZStack {
            RightEarShape(outerRadius: 16, notchRadius: 10)
                .fill(.black)

            if isVisible, let event {
                HStack(spacing: 6) {
                    if let progress = event.progress {
                        ProgressRing(progress: progress, color: event.style.color)
                            .frame(width: 14, height: 14)
                    }

                    if !event.subtitle.isEmpty {
                        Text(event.subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(event.style.color.opacity(0.9))
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
        .onTapGesture { stateManager.expand() }
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

            // Detail
            if let detail = event.detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                    )
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
                    }
                }
                .frame(height: 4)
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

    var body: some View {
        HStack(spacing: 8) {
            Text(event.icon)
                .font(.system(size: 16))
                .scaleEffect(appeared ? 1.0 : 0.5)
                .animation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.1), value: appeared)

            Text(event.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)

            if let progress = event.progress {
                ProgressRing(progress: progress, color: event.style.color)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 38)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(event.icon).font(.system(size: 22))
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
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            }
        }
        .padding(16)
        .frame(width: 380, height: 140)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.black)
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(event.style.glowColor, lineWidth: 1))
                .shadow(color: event.style.glowColor, radius: 12, y: 4)
        )
        .onTapGesture { stateManager.collapse() }
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
        }
    }
}
