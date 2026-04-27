import Foundation

/// Parsed sRGB triplet. Components are normalised `0...1` like
/// SwiftUI's `Color(red:green:blue:)`.
public struct RGB: Equatable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Parse a 6-digit hex colour string (with or without leading `#`)
/// into an sRGB triplet. Returns `nil` for any other shape so callers
/// can fall back to a default rather than render a misleading colour.
public func parseHexColor(_ raw: String) -> RGB? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    return RGB(
        r: Double((v >> 16) & 0xFF) / 255.0,
        g: Double((v >> 8) & 0xFF) / 255.0,
        b: Double(v & 0xFF) / 255.0
    )
}

/// Encode an sRGB triplet as `#RRGGBB`, uppercased. Components are
/// rounded with banker's rounding (Swift's default) and clamped to
/// `0...255` so out-of-range inputs don't overflow the byte.
public func encodeHexColor(_ rgb: RGB) -> String {
    func channel(_ x: Double) -> UInt32 {
        let scaled = (x * 255.0).rounded()
        return UInt32(max(0, min(255, scaled)))
    }
    return String(
        format: "#%02X%02X%02X",
        channel(rgb.r),
        channel(rgb.g),
        channel(rgb.b)
    )
}
