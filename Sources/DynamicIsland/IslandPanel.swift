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

    /// True if this screen has the camera notch cutout. Honours
    /// `DYNAMIC_ISLAND_FORCE_FALLBACK=1` so the fallback layout can be
    /// tested on a notch Mac.
    static func detectHasNotch(for screen: NSScreen) -> Bool {
        if ProcessInfo.processInfo.environment["DYNAMIC_ISLAND_FORCE_FALLBACK"] == "1" {
            return false
        }
        return screen.safeAreaInsets.top > 0
    }

    /// Notch metrics for a screen, or nil if the screen has no notch.
    static func detectNotchDimensions(for screen: NSScreen) -> (width: CGFloat, height: CGFloat)? {
        guard detectHasNotch(for: screen),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            return nil
        }
        let width = right.minX - left.maxX - 1  // sub-pixel compensation
        let height = screen.safeAreaInsets.top
        return (width, height)
    }

    /// Updates the statics `notchWidth` / `notchHeight` for the given screen.
    /// These values are read by `IslandMode.size(hasNotch:)` during panel
    /// size computation, so every call site that changes which screen the
    /// panel lives on MUST call this synchronously before reading size.
    static func applyScreenMetrics(_ screen: NSScreen) {
        if let dims = detectNotchDimensions(for: screen) {
            notchWidth = dims.width
            notchHeight = dims.height
        }
        // If the screen has no notch, leave the fallback defaults in the
        // statics. IslandMode.size(hasNotch: false) ignores them anyway.
    }

    init(stateManager: IslandStateManager) {
        self.stateManager = stateManager

        let screen = NSScreen.main!
        Self.applyScreenMetrics(screen)   // populate statics for this screen
        let hasNotch = Self.detectHasNotch(for: screen)

        let screenFrame = screen.frame
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

    /// Delegates to the static detector using the screen the panel is
    /// currently on. Reads `self.screen` (an `NSWindow` property which
    /// Cocoa updates whenever the panel's frame moves into another
    /// display), falling back to `NSScreen.main` before the panel is
    /// ordered front.
    var hasNotch: Bool {
        guard let screen = self.screen ?? NSScreen.main else { return false }
        return Self.detectHasNotch(for: screen)
    }

    /// Relocate the panel to a different screen. Fades out, re-evaluates
    /// screen-dependent notch metrics, repositions + resizes for the new
    /// screen, then fades in. Safe to call when the requested screen is
    /// already the panel's current screen — short-circuits.
    ///
    /// Must be called on the main thread. The metric update + setFrame
    /// sequence is synchronous so any size read (via
    /// `IslandMode.size(hasNotch:)`) happening during this window sees the
    /// correct statics — see the spec's "Synchronous ordering requirement"
    /// section.
    func relocate(to target: NSScreen, animated: Bool = true) {
        // Short-circuit: already there.
        if let current = self.screen,
           Self.screenNumber(current) == Self.screenNumber(target) {
            return
        }

        let perform: () -> Void = { [weak self] in
            guard let self = self else { return }
            // Synchronous on main: (1) update statics, (2) re-derive hasNotch,
            // (3) compute frame, (4) setFrame. No awaits between.
            Self.applyScreenMetrics(target)
            let hasNotch = Self.detectHasNotch(for: target)

            let size = self.stateManager.mode.size(
                hasNotch: hasNotch,
                sessionRows: self.stateManager.activeSessions.count,
                detailLines: self.stateManager.currentEvent?.detail
                    .map { min($0.split(separator: "\n").count, 10) } ?? 0
            )
            let targetFrame = self.frameOnScreen(target, size: size)
            self.setFrame(targetFrame, display: true)
        }

        guard animated else {
            perform()
            return
        }

        // Fade out → relocate → fade in.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        }, completionHandler: {
            perform()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                self.animator().alphaValue = 1
            })
        })
    }

    /// Convenience called from `IslandStateManager.pushEvent` — resolves
    /// the cursor's screen and relocates there, if it differs.
    func relocateToCursorScreen() {
        let point = NSEvent.mouseLocation
        guard let target = NSScreen.screens.first(where: { $0.frame.contains(point) })
              ?? NSScreen.main else { return }
        relocate(to: target, animated: true)
    }

    // MARK: - Geometry helpers

    private func frameOnScreen(_ screen: NSScreen, size: CGSize) -> NSRect {
        let f = screen.frame
        let x = round(f.midX - size.width / 2)
        let y = f.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func screenNumber(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
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
