import AppKit
import Foundation
import DynamicIslandCore

/// Polls the cursor location every 50ms and fires `onTargetChanged`
/// when the cursor has dwelled on a different screen for 200ms.
///
/// Owned strongly by `AppDelegate`. The callback MUST capture weakly
/// to avoid a cycle back to whatever object (typically the panel)
/// it mutates.
final class ScreenFollower {
    /// Seconds the cursor must stay on a new screen before the callback
    /// fires. 200 ms is the spec's initial value; tune during manual
    /// testing if it feels twitchy (try 300-400 ms).
    var dwellSeconds: TimeInterval = 0.2

    /// Timer tick interval. 50 ms = 20 Hz, which is finer than the dwell
    /// gate so the debounce itself is what determines responsiveness.
    var pollInterval: TimeInterval = 0.05

    /// Fired on the main queue when the cursor has dwelled on a new
    /// screen for `dwellSeconds`. Receives that screen.
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

    /// Called from event-arrival paths (bypasses dwell) — re-evaluates
    /// the cursor screen right now and fires the callback if it differs
    /// from the last emitted one.
    func forceEvaluateNow() {
        guard let (screen, number) = currentCursorScreen() else { return }
        if number != lastEmittedScreenNumber {
            lastEmittedScreenNumber = number
            pendingScreenNumber = nil
            dwellStartedAt = nil
            onTargetChanged?(screen)
        }
    }

    /// Called externally (from AppDelegate's didChangeScreenParameters
    /// handler) when screens connect/disconnect. Clears any stale dwell
    /// state and re-evaluates immediately.
    func handleScreenTopologyChange() {
        pendingScreenNumber = nil
        dwellStartedAt = nil
        // Note: we DON'T clear lastEmittedScreenNumber. If the user's
        // current screen is still present after the change, nothing
        // moves. If it's gone, the next tick will pick up whichever
        // screen contains the cursor (or main screen as fallback).
        forceEvaluateNow()
    }

    // MARK: - Private

    private func tick() {
        guard let (screen, number) = currentCursorScreen() else {
            // Cursor not on any known screen (between displays, in a
            // transitional state, etc.). Leave state alone — next tick
            // will likely resolve.
            return
        }

        if number == lastEmittedScreenNumber {
            // Still on the screen we last emitted. Cancel any pending
            // dwell on a different screen.
            pendingScreenNumber = nil
            dwellStartedAt = nil
            return
        }

        if number != pendingScreenNumber {
            // Cursor just landed on a new non-current screen. Start
            // the dwell timer.
            pendingScreenNumber = number
            dwellStartedAt = Date()
            return
        }

        // Cursor is still on the pending screen. Check dwell elapsed.
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
        let point = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let frames = screens.map { $0.frame }
        guard let idx = ScreenResolver.screenIndex(for: point, in: frames) else {
            return nil
        }
        let screen = screens[idx]
        guard let number = screenDisplayID(screen) else { return nil }
        return (screen, number)
    }

    private func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
