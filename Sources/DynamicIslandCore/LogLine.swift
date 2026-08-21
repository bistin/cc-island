import Foundation

/// Formatting and trimming for the app's log file, kept pure so both can be tested without
/// touching a disk.
///
/// The file itself is written by `DynamicIsland/Log.swift`; everything that decides *what goes in
/// it* and *when it stops growing* is here.
public enum LogLine {

    /// One line: a timestamp to the millisecond, then the message.
    ///
    /// Milliseconds because the questions this file answers are about order and latency — did the
    /// listener bind before or after the other copy quit, how long did the hook sit there — and
    /// second resolution collapses exactly the gaps worth seeing. No date: a line's day is
    /// established by the launch banner above it, and a narrower stamp leaves more room for the
    /// message on one screen width.
    public static func format(at date: Date, _ message: String, calendar: Calendar? = nil) -> String {
        var cal = calendar ?? Calendar(identifier: .gregorian)
        if calendar == nil { cal.timeZone = TimeZone.current }
        let c = cal.dateComponents([.month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        return String(format: "%02d-%02d %02d:%02d:%02d.%03d  %@",
                      c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms,
                      message.replacingOccurrences(of: "\n", with: " "))
    }

    /// How large the file may get before it is trimmed.
    ///
    /// A log nobody rotates is a log that eventually fills a disk, and one that rotates by
    /// deleting is a log that throws away the morning you needed. One mebibyte is tens of
    /// thousands of lines — far more history than any of these questions reach back for — and is
    /// small enough that reading the whole thing to trim it costs nothing.
    public static let maximumBytes = 1_048_576

    /// The most recent half, cut at a line boundary, or nil when the file is small enough to leave
    /// alone.
    ///
    /// **Half rather than all**, so trimming happens rarely instead of on every write once the cap
    /// is reached. Cutting at a newline matters because the first surviving line would otherwise
    /// be a fragment that reads like a corrupt entry rather than a truncation.
    public static func trimmed(_ contents: String, maximumBytes: Int = maximumBytes) -> String? {
        guard contents.utf8.count > maximumBytes else { return nil }
        let keep = max(1, maximumBytes / 2)
        var tail = String(decoding: contents.utf8.suffix(keep), as: UTF8.self)
        if let newline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: newline)...])
        }
        return "…earlier entries trimmed\n" + tail
    }
}
