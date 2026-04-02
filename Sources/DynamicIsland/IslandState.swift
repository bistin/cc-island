import Foundation
import SwiftUI

// MARK: - Event Model

struct IslandEvent: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String
    let style: EventStyle
    let duration: TimeInterval
    let detail: String?
    let progress: Double?
    let persistent: Bool  // if true, won't auto-dismiss

    init(
        icon: String = "",
        title: String,
        subtitle: String = "",
        style: EventStyle = .info,
        duration: TimeInterval = 4.0,
        detail: String? = nil,
        progress: Double? = nil,
        persistent: Bool = false
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.duration = duration
        self.detail = detail
        self.progress = progress
        self.persistent = persistent
    }
}

enum EventStyle: String, Codable {
    case info
    case success
    case warning
    case error
    case claude // Claude Code specific
    case action // Needs user attention — persistent, pulsing

    var color: Color {
        switch self {
        case .info: return .white
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .claude: return Color(red: 0.85, green: 0.65, blue: 0.45)
        case .action: return Color(red: 0.4, green: 0.7, blue: 1.0) // bright blue
        }
    }

    var glowColor: Color {
        switch self {
        case .info: return .white.opacity(0.3)
        case .success: return .green.opacity(0.4)
        case .warning: return .orange.opacity(0.4)
        case .error: return .red.opacity(0.4)
        case .claude: return Color(red: 0.85, green: 0.65, blue: 0.45).opacity(0.4)
        case .action: return Color(red: 0.4, green: 0.7, blue: 1.0).opacity(0.6)
        }
    }
}

// MARK: - Display Mode

enum IslandMode: Equatable {
    case compact
    case expanded
    case hidden

    /// Window size — compact hugs the notch, expanded drops below it
    func size(hasNotch: Bool) -> CGSize {
        if hasNotch {
            let w = IslandPanel.earWidth * 2 + IslandPanel.notchWidth
            switch self {
            case .compact: return CGSize(width: w, height: IslandPanel.notchHeight + 30) // extra room for thinking glow
            case .expanded: return CGSize(width: w, height: IslandPanel.notchHeight + 130)
            case .hidden: return CGSize(width: w, height: IslandPanel.notchHeight + 30)
            }
        } else {
            switch self {
            case .compact: return CGSize(width: 210, height: 38)
            case .expanded: return CGSize(width: 380, height: 140)
            case .hidden: return CGSize(width: 210, height: 38)
            }
        }
    }
}

// MARK: - State Manager

class IslandStateManager: ObservableObject {
    @Published var mode: IslandMode = .hidden
    @Published var currentEvent: IslandEvent?
    @Published var isHovered = false
    @Published var isThinking = false

    private var eventQueue: [IslandEvent] = []
    private var dismissTimer: Timer?
    private var isProcessing = false

    func pushEvent(_ event: IslandEvent) {
        DispatchQueue.main.async {
            self.eventQueue.append(event)
            if !self.isProcessing {
                self.processNext()
            }
        }
    }

    private func processNext() {
        guard !eventQueue.isEmpty else {
            isProcessing = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                mode = .hidden
                currentEvent = nil
            }
            return
        }

        isProcessing = true
        let event = eventQueue.removeFirst()

        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            currentEvent = event
            mode = .compact
        }

        dismissTimer?.invalidate()
        if !event.persistent {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: event.duration, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, !self.isHovered else { return }
                    self.dismiss()
                }
            }
        }
    }

    func expand() {
        guard currentEvent != nil else { return }
        dismissTimer?.invalidate()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            mode = .expanded
        }
    }

    func collapse() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            mode = .compact
        }
        // Restart dismiss timer
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            mode = .hidden
            currentEvent = nil
        }
        // Small delay before processing next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.processNext()
        }
    }

    func startThinking() {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.6)) {
                self.isThinking = true
            }
        }
    }

    func stopThinking() {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.8)) {
                self.isThinking = false
            }
        }
    }
}
