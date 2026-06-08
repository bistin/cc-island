import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Normalize raw `ps -o tty= -p <pid>` output into a `/dev/<name>` path.
///
/// `ps` writes the bare device name (e.g. `ttys003`) for processes attached to
/// a controlling terminal, `?` or `??` for daemons, and an empty string when
/// the pid doesn't exist. Returns nil for any non-tty answer so callers don't
/// have to special-case them.
public func parsePSTTYOutput(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "?", trimmed != "??" else { return nil }
    if trimmed.hasPrefix("/dev/") { return trimmed }
    return "/dev/\(trimmed)"
}

/// Resolve the controlling TTY of `parentPID` by shelling out to `ps`.
///
/// The hook's own stdio is piped from Claude Code, so `ttyname(0)` is useless
/// here — we walk one hop up the process tree (`getppid()` by default) and
/// ask `ps` for that parent's controlling terminal. The returned path is what
/// `Terminal.app`/`iTerm2` expose as the `tty` of a tab/session, so a click
/// on the island can find the right tab without any extra correlation.
///
/// Returns nil if `ps` is missing, fails, or the parent isn't attached to a
/// terminal (e.g. Codex/Copilot launched from a GUI app, or self-test).
public func detectControllingTTY(parentPID: Int32 = getppid()) -> String? {
    let psPath = "/bin/ps"
    guard FileManager.default.isExecutableFile(atPath: psPath) else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: psPath)
    process.arguments = ["-o", "tty=", "-p", "\(parentPID)"]
    let stdout = Pipe()
    process.standardOutput = stdout
    // Discard stderr so a noisy ps doesn't pollute the hook's stderr.
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    guard let raw = String(data: data, encoding: .utf8) else { return nil }
    return parsePSTTYOutput(raw)
}
