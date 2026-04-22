import AppKit
import Combine
import SwiftUI

class IslandPanel: NSPanel {
    let stateManager: IslandStateManager
    private var cancellables: Set<AnyCancellable> = []

    // Auto-detected from screen, with sensible fallbacks
    static var notchWidth: CGFloat = 185
    static var notchHeight: CGFloat = 32
    static let earWidth: CGFloat = 140

    /// Detect actual notch dimensions from the current screen
    static func detectNotch() {
        guard let screen = NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            return
        }
        notchWidth = right.minX - left.maxX - 1 // sub-pixel compensation
        notchHeight = screen.safeAreaInsets.top
        print("[DynamicIsland] Detected notch: \(notchWidth)pt × \(notchHeight)pt")
    }

    init(stateManager: IslandStateManager) {
        self.stateManager = stateManager

        let screen = NSScreen.main!
        let screenFrame = screen.frame
        let hasNotch = screen.safeAreaInsets.top > 0

        // Detect actual notch size
        if hasNotch { Self.detectNotch() }

        let totalWidth: CGFloat = hasNotch ? (Self.earWidth * 2 + Self.notchWidth) : 210
        let height: CGFloat = hasNotch ? Self.notchHeight : 38

        let x = round(screenFrame.midX - totalWidth / 2)
        let y = screenFrame.maxY - height

        let rect = NSRect(x: x, y: y, width: totalWidth, height: height)

        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Above menu bar to sit at notch level
        self.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.hidesOnDeactivate = false
        // Start click-through; toggled on when there's something to interact with.
        self.ignoresMouseEvents = true
        self.acceptsMouseMovedEvents = true

        let hostView = NSHostingView(
            rootView: IslandRootView(stateManager: stateManager, panel: self)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        hostView.layer?.backgroundColor = .clear
        self.contentView = hostView

        // Pass clicks through to whatever is behind the notch when no event is
        // showing — without this, the panel's transparent gap blocks menu-bar
        // items behind the camera notch.
        Publishers.CombineLatest(stateManager.$mode, stateManager.$currentEvent)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode, event in
                self?.ignoresMouseEvents = (mode == .hidden && event == nil)
            }
            .store(in: &cancellables)
    }

    func show() {
        orderFrontRegardless()
    }

    var hasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }

    func updateSize(to size: CGSize, animated: Bool = true) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame

        let x = round(screenFrame.midX - size.width / 2)
        // Compact/hidden: flush with top. Expanded: extends downward from top.
        let y = screenFrame.maxY - size.height

        let newFrame = NSRect(x: x, y: y, width: size.width, height: size.height)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }
}
