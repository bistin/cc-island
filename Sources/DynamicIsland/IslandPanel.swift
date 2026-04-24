import AppKit
import Combine
import SwiftUI

class IslandPanel: NSPanel {
    let stateManager: IslandStateManager
    private var cancellables: Set<AnyCancellable> = []
    private var pulsePanel: PulseWindow?

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

        // Thinking pulse lives in a separate transparent child window so the
        // glow can spread below the notch without enlarging the main panel's
        // hittable frame. `ignoresMouseEvents` is window-scoped, so sharing a
        // frame with the ears would force clicks in the pulse strip to be
        // blocked alongside clicks in the ears. Child window auto-follows the
        // main panel on move; we still hide/show it based on isThinking.
        let pulseSize = NSSize(width: Self.earWidth * 2 + Self.notchWidth, height: 30)
        let pulse = PulseWindow(size: pulseSize)
        let pulseHost = NSHostingView(rootView: PulseRootView(stateManager: stateManager))
        pulseHost.layer?.backgroundColor = .clear
        pulse.contentView = pulseHost
        pulse.setFrame(NSRect(
            x: rect.midX - pulseSize.width / 2,
            y: rect.minY - pulseSize.height,
            width: pulseSize.width,
            height: pulseSize.height
        ), display: false)
        self.pulsePanel = pulse
        self.addChildWindow(pulse, ordered: .above)

        stateManager.$isThinking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePulseVisibility()
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
    func relocate(to target: NSScreen) {
        if let current = self.screen, current === target { return }
        if let current = self.screen,
           let a = current.displayID, let b = target.displayID, a == b { return }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            Self.applyScreenMetrics(target)
            let hasNotch = Self.detectHasNotch(for: target)
            let size = Self.adjustedSize(
                mode: self.stateManager.mode,
                event: self.stateManager.currentEvent,
                hasNotch: hasNotch,
                sessionRows: self.stateManager.activeSessions.count,
                detailLines: self.stateManager.currentEvent?.detail
                    .map { min($0.split(separator: "\n").count, 10) } ?? 0
            )
            let newFrame = Self.topCenteredFrame(on: target, size: size)
            self.setFrame(newFrame, display: true)
            self.syncPulsePanelFrame(mainFrame: newFrame)
            self.updatePulseVisibility()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self.animator().alphaValue = 1
            }
        })
    }

    /// Resolve the cursor's screen and relocate there. Called from
    /// `IslandStateManager.pushEvent` so events appear on whichever
    /// screen the user is currently working on.
    func relocateToCursorScreen() {
        guard let target = NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main else { return }
        relocate(to: target)
    }

    /// Post-processes the raw `IslandMode.size(...)` result: in notch layout
    /// compact/hidden shrink to `notchHeight` since the thinking pulse lives
    /// in its own window now and the +30 pt strip would just block clicks.
    /// Called from both `IslandRootView.updatePanelSize` and `relocate(to:)`
    /// so every size computation stays in sync.
    static func adjustedSize(
        mode: IslandMode,
        event: IslandEvent?,
        hasNotch: Bool,
        sessionRows: Int,
        detailLines: Int
    ) -> CGSize {
        var size = mode.size(
            hasNotch: hasNotch,
            sessionRows: sessionRows,
            detailLines: detailLines
        )
        if hasNotch && mode != .expanded {
            size.height = notchHeight
        }
        return size
    }

    /// Top-centered frame on `screen`. Used by both `init` (via inline
    /// duplication for super.init ordering) and `updateSize` / `relocate`.
    static func topCenteredFrame(on screen: NSScreen, size: CGSize) -> NSRect {
        let f = screen.frame
        let x = round(f.midX - size.width / 2)
        let y = f.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func updateSize(to size: CGSize, animated: Bool = true) {
        // Use the screen the panel is currently on, not NSScreen.main.
        // After `relocate(to:)`, the panel may be on a secondary screen;
        // sizing against main would mis-place it.
        guard let screen = self.screen ?? NSScreen.main else { return }
        let newFrame = Self.topCenteredFrame(on: screen, size: size)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
        syncPulsePanelFrame(mainFrame: newFrame)
    }

    /// Re-anchor the pulse child window to just below the main panel. The
    /// child-window relationship preserves relative offset on parent MOVE,
    /// but parent RESIZE leaves the pulse at a stale y since the offset
    /// between bottom edges changes with main height. Call this after every
    /// main-panel frame change.
    private func syncPulsePanelFrame(mainFrame: NSRect) {
        guard let pulse = pulsePanel else { return }
        let w = pulse.frame.width
        let h = pulse.frame.height
        pulse.setFrame(NSRect(
            x: mainFrame.midX - w / 2,
            y: mainFrame.minY - h,
            width: w,
            height: h
        ), display: true)
    }

    /// Pulse only makes visual sense under the notch — in fallback/capsule
    /// mode there's no notch to anchor it to, and our 465 pt pulse window
    /// would float orphaned 30 pt below a narrower pill. Hide in that case.
    /// Call whenever `isThinking` or the active screen changes.
    func updatePulseVisibility() {
        guard let pulse = pulsePanel else { return }
        if stateManager.isThinking && hasNotch {
            pulse.orderFrontRegardless()
        } else {
            pulse.orderOut(nil)
        }
    }
}

/// Transparent child window housing the thinking pulse. Fully click-through
/// (`ignoresMouseEvents = true`) so the glow strip below the notch never
/// steals clicks from the app underneath. Main `IslandPanel` owns this as
/// a child window so it follows on screen relocates.
final class PulseWindow: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.hidesOnDeactivate = false
    }
}
