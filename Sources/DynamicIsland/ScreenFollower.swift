import AppKit
import Foundation
import DynamicIslandCore

/// Polls the cursor at 20 Hz and fires `onTargetChanged` when the cursor
/// has dwelled on a different screen for `dwellSeconds`. The dwell value
/// is read live from `dynamicIslandUserDefaults` (#41 settings panel) so
/// changes from the Settings panel apply on the next cursor move without
/// a restart. The default (200 ms) lives in the `positiveDouble`
/// fallback — non-positive / unset stored values fall back to it.
final class ScreenFollower {
    /// Live dwell horizon. Reads `screenFollowerDwellKey` (ms units in
    /// UserDefaults) per access and converts to seconds. Per-tick read
    /// is cheap; doing it inside `tick()` keeps the value reactive.
    var dwellSeconds: TimeInterval {
        positiveDouble(
            dynamicIslandUserDefaults,
            forKey: screenFollowerDwellKey,
            default: 200
        ) / 1000
    }
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
