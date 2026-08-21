import Foundation
import DynamicIslandCore

/// A file at `~/Library/Logs/CLI Island.log`, because an app with no window and no Dock icon says
/// nothing at all when something goes wrong.
///
/// The diagnosis often already exists and is simply unreachable: `LocalServer` has always printed
/// "Server failed" on a bind error, and an `LSUIElement` app launched from Finder has no stdout
/// anybody will ever read. That exact case came up while working on this — the app was running,
/// nothing was listening on 9423, and there was no way to tell from outside except by noticing
/// that events had stopped arriving.
///
/// **Routes and outcomes, never payloads.** What a session asked, what a file contained, what a
/// command was — none of that belongs in a file that outlives the moment and that somebody may
/// paste into an issue. What belongs here is which path the code took and what it got back:
/// bound or failed, tmux or AppleScript or neither, installed or already in sync.
enum Log {
    private static let queue = DispatchQueue(label: "dev.bistin.DynamicIsland.log")

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CLI Island.log")

    /// Append one line. Never throws and never blocks the caller on I/O — a logger that can break
    /// the thing it is observing is worse than no logger.
    static func write(_ message: String) {
        let line = LogLine.format(at: Date(), message) + "\n"
        // Also to stdout when there is one, so `swift run` keeps showing what it always did.
        if isatty(STDOUT_FILENO) == 1 { print("[CLI Island] \(message)") }
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
            trimIfNeeded()
        }
    }

    /// Marks a launch, so the lines below it have a day and a build to belong to.
    static func banner(version: String, build: String) {
        write("— CLI Island \(version) (\(build)) started, pid \(ProcessInfo.processInfo.processIdentifier)")
    }

    private static func trimIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > LogLine.maximumBytes,
              let contents = try? String(contentsOf: url, encoding: .utf8),
              let trimmed = LogLine.trimmed(contents) else { return }
        try? trimmed.write(to: url, atomically: true, encoding: .utf8)
    }
}
