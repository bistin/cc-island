#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Capture the island for documentation, with the notch painted back in.
//
// `screencapture` records what the display is *rendering*, and macOS renders the notch region as
// menu-bar background — so a straight screenshot shows the two ears with a strip of wallpaper
// between them, and the island reads as two floating blobs instead of one shape. On the machine
// itself that strip is a physical black cutout. Filling it black is not retouching; it is
// restoring the one part of the picture the screenshot cannot see.
//
//   swift scripts/capture-island.swift out.png [--height 240] [--width 900] [--delay 1.5]
//
// --height covers the expanded panel; the default is the menu-bar band alone.

func arg(_ name: String, _ fallback: Double) -> Double {
    guard let i = CommandLine.arguments.firstIndex(of: name),
          i + 1 < CommandLine.arguments.count,
          let v = Double(CommandLine.arguments[i + 1]) else { return fallback }
    return v
}

let output = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "island.png"
let bandHeight = arg("--height", 44)
let bandWidth = arg("--width", 1000)
let delay = arg("--delay", 0.8)

guard let screen = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) ?? NSScreen.main else {
    FileHandle.standardError.write(Data("no screen\n".utf8)); exit(1)
}
let scale = screen.backingScaleFactor

// The notch, in points, from the two menu-bar areas macOS reports either side of it — the gap
// between them *is* the notch, on any model. nil on a display without one, where nothing needs
// painting because there is no cutout to restore.
var notchPixels: CGRect?
if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, r.minX > l.maxX {
    notchPixels = CGRect(x: l.maxX * scale, y: 0,
                         width: (r.minX - l.maxX) * scale,
                         height: screen.safeAreaInsets.top * scale)
}

// A plain backdrop, when asked for. Without one these shots carry whatever the desktop happened
// to be showing — menu-bar extras, window titles, somebody's terminal — into a public README. It
// is still a real screenshot: a real window is really on screen, sitting below the island's level
// and above everything else, so the island is photographed rather than composited.
var backdrop: NSWindow?
if CommandLine.arguments.contains("--backdrop") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                          backing: .buffered, defer: false, screen: screen)
    window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
    window.isOpaque = true
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    let view = NSView(frame: screen.frame)
    view.wantsLayer = true
    let gradient = CAGradientLayer()
    gradient.frame = screen.frame
    gradient.colors = [CGColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1),
                       CGColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1)]
    view.layer = gradient
    window.contentView = view
    window.orderFrontRegardless()
    backdrop = window
    // Let the window server actually paint it before the shutter.
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
}
defer { backdrop?.orderOut(nil) }

Thread.sleep(forTimeInterval: delay)

let temp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("island-capture-\(UUID().uuidString).png")
let capture = Process()
capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
capture.arguments = ["-x", temp.path]
try capture.run()
capture.waitUntilExit()
defer { try? FileManager.default.removeItem(at: temp) }

// CGImage rather than NSImage throughout, and pixels rather than points. An NSImage loaded from a
// Retina capture reports its size in points, so mixing the two silently samples the wrong region
// and rescales — which produced a blank frame with a black rectangle in it the first time.
guard let data = try? Data(contentsOf: temp),
      let sourceRef = CGImageSourceCreateWithData(data as CFData, nil),
      let full = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil) else {
    FileHandle.standardError.write(Data("could not read the capture\n".utf8)); exit(1)
}
let pixelWidth = CGFloat(full.width), pixelHeight = CGFloat(full.height)

// Centred on the notch rather than on the screen: the island is built around the cutout, and on a
// display without one the centre is where the capsule sits anyway.
let centreX = notchPixels.map { $0.midX } ?? pixelWidth / 2
let cropWidth = min(bandWidth * scale, pixelWidth)
let cropHeight = min(bandHeight * scale, pixelHeight)
// CGImage coordinates run from the top left, which is also where the menu bar is.
let crop = CGRect(x: max(0, min(centreX - cropWidth / 2, pixelWidth - cropWidth)),
                  y: 0, width: cropWidth, height: cropHeight)

guard let cropped = full.cropping(to: crop),
      let context = CGContext(data: nil,
                              width: Int(cropWidth), height: Int(cropHeight),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("could not build the output\n".utf8)); exit(1)
}
context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))

if let notch = notchPixels {
    // The context's origin is bottom left; the notch is at the top of the band.
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: notch.minX - crop.minX,
                        y: cropHeight - notch.height,
                        width: notch.width, height: notch.height))
}

guard let result = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("could not encode\n".utf8)); exit(1)
}
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write \(output)\n".utf8)); exit(1)
}
print("\(output)  \(Int(cropWidth))x\(Int(cropHeight))px" + (notchPixels == nil ? "  (no notch)" : "  notch filled"))
