import SwiftUI

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
