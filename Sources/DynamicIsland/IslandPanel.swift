import AppKit
import SwiftUI

class IslandPanel: NSPanel {
    let stateManager: IslandStateManager
    static let notchWidth: CGFloat = 180  // 14" MBP notch width in pt
    static let notchHeight: CGFloat = 32  // notch height in pt
    static let earWidth: CGFloat = 180    // fixed ear width

    init(stateManager: IslandStateManager) {
        self.stateManager = stateManager

        let screen = NSScreen.main!
        let screenFrame = screen.frame
        let hasNotch = screen.safeAreaInsets.top > 0

        // Wide enough for notch + generous ear space
        let totalWidth: CGFloat = hasNotch ? (Self.earWidth * 2 + Self.notchWidth) : 210
        let height: CGFloat = hasNotch ? Self.notchHeight : 38

        let x = round(screenFrame.midX - totalWidth / 2)
        let y = screenFrame.maxY - height // Flush with top edge

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
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true

        let hostView = NSHostingView(
            rootView: IslandRootView(stateManager: stateManager, panel: self)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        hostView.layer?.backgroundColor = .clear
        self.contentView = hostView
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
