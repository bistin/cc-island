import SwiftUI

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
