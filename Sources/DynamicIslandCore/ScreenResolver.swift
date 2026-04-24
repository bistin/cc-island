import Foundation
import CoreGraphics

/// Pure, platform-agnostic screen-resolution logic extracted from
/// `ScreenFollower` so it can be unit-tested without AppKit.
///
/// Call sites translate `NSScreen.screens` → `[CGRect]` and
/// `NSEvent.mouseLocation` → `CGPoint` (both are in global
/// bottom-left-origin coordinates, so the geometry is already compatible).
public enum ScreenResolver {
    /// Returns the index in `frames` of the first rect that contains
    /// `point`, or `nil` if none do. Uses `CGRect.contains`, which treats
    /// the max edges as exclusive — if a point sits exactly on the right
    /// or top edge, the adjacent screen (if any) wins.
    public static func screenIndex(for point: CGPoint, in frames: [CGRect]) -> Int? {
        for (idx, frame) in frames.enumerated() where frame.contains(point) {
            return idx
        }
        return nil
    }
}
