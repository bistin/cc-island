// Renders the app icon into an .iconset directory, ready for `iconutil`.
//
//   swift scripts/render-app-icon.swift build/AppIcon.iconset
//   iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
//
// AppKit only — same "no external dependencies" rule the app itself follows,
// so the icon stays reproducible from source instead of being a binary blob
// nobody can regenerate.
//
// The mark: a black island pill holding a shell prompt. The pill is the notch
// this app lives in; the `>` and the block cursor say the events come from
// CLI coding agents. Colours are the app's own source palette (Claude orange,
// Codex green) so the icon speaks the same language as the ears on screen.

import AppKit

// Art is authored against a 1024 grid and scaled per output size, so every
// size is drawn as vectors rather than downsampled from one master.
let grid: CGFloat = 1024
let inset: CGFloat = 100          // Big Sur icon margin: art fills 824 of 1024
let plateRect = NSRect(x: inset, y: inset, width: grid - inset * 2, height: grid - inset * 2)
let plateRadius: CGFloat = 185

let claudeOrange = NSColor(srgbRed: 0.898, green: 0.671, blue: 0.427, alpha: 1)
let codexGreen = NSColor(srgbRed: 0.310, green: 0.851, blue: 0.631, alpha: 1)

func plate() -> NSBezierPath {
    NSBezierPath(roundedRect: plateRect, xRadius: plateRadius, yRadius: plateRadius)
}

func pill(_ rect: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
}

func drawPlate() {
    plate().addClip()
    NSGradient(
        starting: NSColor(srgbRed: 0.161, green: 0.173, blue: 0.208, alpha: 1),
        ending: NSColor(srgbRed: 0.039, green: 0.047, blue: 0.067, alpha: 1)
    )?.draw(in: plateRect, angle: -90)

    // Lit from the top, the way macOS system icons are.
    if let sheen = NSGradient(
        colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)]
    ) {
        sheen.draw(
            in: NSRect(x: inset, y: grid - inset - 320, width: grid - inset * 2, height: 320),
            angle: -90
        )
    }

    let rim = plate()
    rim.lineWidth = 4
    NSColor.white.withAlphaComponent(0.12).setStroke()
    rim.stroke()
}

/// - Parameter simplified: at 32px and below the cursor block and the chevron
///   collide into a smudge, so small sizes drop the cursor and enlarge the
///   chevron. Standard icon practice — legibility beats literal consistency.
func drawIcon(simplified: Bool) {
    drawPlate()
    plate().addClip()

    let island = NSRect(x: 232, y: 372, width: 560, height: 280)
    NSColor(srgbRed: 0.016, green: 0.020, blue: 0.031, alpha: 1).setFill()
    pill(island).fill()

    let rim = pill(island)
    rim.lineWidth = 7
    NSColor.white.withAlphaComponent(0.22).setStroke()
    rim.stroke()

    let midX = island.midX
    let midY = island.midY

    if simplified {
        let width: CGFloat = 150
        let halfHeight: CGFloat = 114
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: midX - width / 2, y: midY + halfHeight))
        chevron.line(to: NSPoint(x: midX + width / 2, y: midY))
        chevron.line(to: NSPoint(x: midX - width / 2, y: midY - halfHeight))
        claudeOrange.setStroke()
        chevron.lineWidth = 64
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()
        return
    }

    // Chevron and cursor are laid out as one group, then centred together.
    let chevronWidth: CGFloat = 108
    let chevronHalfHeight: CGFloat = 82
    let gap: CGFloat = 54
    let cursorWidth: CGFloat = 58
    let cursorHeight: CGFloat = 150
    let startX = midX - (chevronWidth + gap + cursorWidth) / 2

    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: startX, y: midY + chevronHalfHeight))
    chevron.line(to: NSPoint(x: startX + chevronWidth, y: midY))
    chevron.line(to: NSPoint(x: startX, y: midY - chevronHalfHeight))
    claudeOrange.setStroke()
    chevron.lineWidth = 46
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.stroke()

    let cursor = NSRect(
        x: startX + chevronWidth + gap,
        y: midY - cursorHeight / 2,
        width: cursorWidth,
        height: cursorHeight
    )
    codexGreen.setFill()
    NSBezierPath(roundedRect: cursor, xRadius: 18, yRadius: 18).fill()
}

func renderPNG(pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("bitmap alloc failed at \(pixels)px") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let scale = CGFloat(pixels) / grid
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    drawIcon(simplified: pixels <= 32)

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed at \(pixels)px")
    }
    return data
}

// (filename, pixel size) — the full set `iconutil` expects.
let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.iconset"

try! FileManager.default.createDirectory(
    atPath: outputDir, withIntermediateDirectories: true
)

for (name, pixels) in outputs {
    let data = renderPNG(pixels: pixels)
    try! data.write(to: URL(fileURLWithPath: "\(outputDir)/\(name)"))
}
print("wrote \(outputs.count) sizes to \(outputDir)")
