import AppKit

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
    static func containing(_ point: CGPoint) -> NSScreen? {
        screens.first(where: { $0.frame.contains(point) })
    }
}
