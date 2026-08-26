import AppKit
import DynamicIslandCore

extension NSDeviceDescriptionKey {
    /// Typed wrapper around the documented `"NSScreenNumber"` key — AppKit
    /// doesn't vend a symbol, so we mint one here and use it everywhere
    /// that reads an `NSScreen`'s `CGDirectDisplayID`.
    static let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
}

extension NSScreen {
    /// The screen's `CGDirectDisplayID`, or nil if unavailable (rare — happens
    /// briefly during screen-topology transitions).
    var displayID: CGDirectDisplayID? {
        deviceDescription[.screenNumber] as? CGDirectDisplayID
    }

    /// The first screen whose `frame` contains `point`, or nil if the point
    /// lies outside every connected display. Matches `NSEvent.mouseLocation`'s
    /// global bottom-left coordinate system.
    ///
    /// Delegates to `ScreenResolver`, which existed for exactly this and had no caller: the
    /// formula was written here as well, so the tested copy was the dead one. Two implementations
    /// of point-in-rect is one more than is worth having, and it was the untested one that ran.
    static func containing(_ point: CGPoint) -> NSScreen? {
        let all = screens
        guard let idx = ScreenResolver.screenIndex(for: point, in: all.map(\.frame)) else {
            return nil
        }
        return all[idx]
    }
}
