import AppKit
import Foundation
import DynamicIslandCore

/// Polls the cursor at 20 Hz and fires `onTargetChanged` when the cursor
/// has dwelled on a different screen for `dwellSeconds`. Bump
/// `dwellSeconds` (300–400 ms) if 200 ms feels twitchy in practice.
final class ScreenFollower {
    var dwellSeconds: TimeInterval = 0.2
    var pollInterval: TimeInterval = 0.05
    var onTargetChanged: ((NSScreen) -> Void)?

    private var timer: Timer?
    private var lastEmittedScreenNumber: CGDirectDisplayID?
    private var pendingScreenNumber: CGDirectDisplayID?
    private var dwellStartedAt: Date?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingScreenNumber = nil
        dwellStartedAt = nil
    }

    /// Bypass the dwell timer and re-evaluate the cursor's screen now.
    /// Fires the callback if the screen differs from the last emitted.
    func forceEvaluateNow() {
        guard let (screen, number) = currentCursorScreen() else { return }
        if number != lastEmittedScreenNumber {
            lastEmittedScreenNumber = number
            pendingScreenNumber = nil
            dwellStartedAt = nil
            onTargetChanged?(screen)
        }
    }

    /// Called when screens connect/disconnect. Clears pending dwell
    /// state and re-evaluates. Keeps `lastEmittedScreenNumber` so a
    /// still-present current screen doesn't trigger a needless move.
    func handleScreenTopologyChange() {
        pendingScreenNumber = nil
        dwellStartedAt = nil
        forceEvaluateNow()
    }

    // MARK: - Private

    private func tick() {
        guard let (screen, number) = currentCursorScreen() else { return }

        if number == lastEmittedScreenNumber {
            pendingScreenNumber = nil
            dwellStartedAt = nil
            return
        }

        if number != pendingScreenNumber {
            pendingScreenNumber = number
            dwellStartedAt = Date()
            return
        }

        if let started = dwellStartedAt,
           Date().timeIntervalSince(started) >= dwellSeconds {
            lastEmittedScreenNumber = number
            pendingScreenNumber = nil
            dwellStartedAt = nil
            onTargetChanged?(screen)
        }
    }

    /// Returns the screen the cursor is currently over and its
    /// `CGDirectDisplayID`, or nil if the cursor isn't over any known
    /// screen.
    private func currentCursorScreen() -> (NSScreen, CGDirectDisplayID)? {
        guard let screen = NSScreen.containing(NSEvent.mouseLocation),
              let id = screen.displayID else { return nil }
        return (screen, id)
    }
}
