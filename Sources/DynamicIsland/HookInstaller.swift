import DynamicIslandCore
import Foundation
import IslandHookCore

/// Shared UserDefaults store for app-wide preferences.
///
/// Resolution order:
/// 1. `Bundle.main.bundleIdentifier` — the production `.app` always
///    has this from `Info.plist`. Forks that change the bundle id pick
///    up the new value automatically here, no source edit needed.
/// 2. `com.cc-island.dynamic-island` fallback — used when
///    `Bundle.main.bundleIdentifier` is nil, which happens for
///    SwiftPM-built executables (CLI `--install-hooks`, debug GUI
///    launches from `.build/debug/`). Without a fallback,
///    `UserDefaults.standard` would resolve to an unrelated domain
///    and the dogfood flag would silently disagree across processes.
/// 3. `.standard` — last resort if `UserDefaults(suiteName:)` itself
///    fails for some reason.
///
/// For forks running their own SPM CLI build, the (2) fallback won't
/// match their bundle id, so dogfood toggles via `defaults write
/// <fork.id> enableInlineReply` won't surface in a bare CLI run; the
/// `.app` build path keeps working because (1) wins. Practically
/// non-issue unless a fork dogfoods the inline reply flag through
/// `--install-hooks` directly.
let dynamicIslandUserDefaults: UserDefaults = {
    if let id = Bundle.main.bundleIdentifier,
       let store = UserDefaults(suiteName: id) {
        return store
    }
    return UserDefaults(suiteName: "com.cc-island.dynamic-island") ?? .standard
}()

/// UserDefaults key gating Phase 2 inline-reply UI (#36). Same string
/// referenced by `@AppStorage` in `ExpandedContentView` /
/// `ExpandedPillView`, by `HookInstaller.commandString` to decide
/// whether to inject the env var, and by `IslandPanel.canBecomeKey`
/// to allow keyboard focus only when a reply field is on screen.
let enableInlineReplyKey = "enableInlineReply"

/// UserDefaults key for the Stop reply long-poll horizon, in seconds (#41).
/// Read by `HookInstaller.commandString` (injected as `CC_ISLAND_STOP_TIMEOUT`
/// env) and by `HookInstaller.events` (mirrored into the Stop entry's
/// `timeout` field, with a +5 s round-trip buffer). Default `30`.
let stopReplyTimeoutKey = "stopReplyTimeoutSeconds"

/// UserDefaults key for the screen-follower dwell debounce, in
/// milliseconds (#41). Read at runtime by `ScreenFollower` per cursor
/// move. Default `200`.
let screenFollowerDwellKey = "screenFollowerDwellMilliseconds"

/// Read a positive `Double` UserDefault, falling back to `defaultValue`
/// when the key is unset, malformed, or `<= 0`.
///
/// `UserDefaults.double(forKey:)` returns `0` for an unset key, which
/// would silently make a 30-second long-poll instantaneous or freeze
/// the screen-follower dwell. This wrapper makes the fallback contract
/// explicit at every read site (#41 review).
func positiveDouble(
    _ store: UserDefaults,
    forKey key: String,
    default defaultValue: Double
) -> Double {
    let raw = store.double(forKey: key)
    return raw > 0 ? raw : defaultValue
}

/// Format a `Double` for the `CC_ISLAND_STOP_TIMEOUT=…` env injection.
/// `%g` strips trailing zeros so a default of `30.0` renders as `30`,
/// keeping the on-disk command string canonical.
func formatStopTimeout(_ value: Double) -> String {
    String(format: "%g", value)
}

/// Deploys the bundled `island-hook` binary and registers hook events for
/// Claude Code (`~/.claude/settings.json`), GitHub Copilot
/// (`{repo}/.github/hooks/hooks.json`), or OpenAI Codex (`~/.codex/hooks.json`).
///
/// The formats differ:
///   Claude Code: { "matcher": "pattern", "hooks": [{ type, command, timeout }] }
///   Codex:       { "matcher": "pattern", "hooks": [{ type, command, timeout }] }
///   Copilot:     { type, command, timeout }   (flat, no matcher)
enum HookInstaller {

    enum Result {
        case installed         // hooks written or updated
        case alreadyCurrent    // settings already match desired state
        case removed           // uninstall succeeded
        case notInstalled      // nothing to remove
        case skipped(String)   // source hook script not found (dev build)
        case failed(String)
    }

    enum Target {
        case claudeCode
        /// Copilot hooks are per-repo, written to `{repoPath}/.github/hooks/hooks.json`.
        case copilot(repoPath: URL)
        case codex

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .copilot:    return "Copilot"
            case .codex:      return "Codex"
            }
        }

        var deployedHookURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeCode:
                return home.appendingPathComponent(".claude/hooks/dynamic-island-hook")
            case .copilot:
                // Binary lives globally; each repo's config just references it.
                return home.appendingPathComponent(".copilot/hooks/dynamic-island-hook")
            case .codex:
                return home.appendingPathComponent(".codex/hooks/dynamic-island-hook")
            }
        }

        var settingsURL: URL {
            switch self {
            case .claudeCode:
                return FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/settings.json")
            case .copilot(let repoPath):
                return repoPath.appendingPathComponent(".github/hooks/hooks.json")
            case .codex:
                return FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex/hooks.json")
            }
        }

        var usesMatcher: Bool {
            switch self {
            case .claudeCode: return true
            case .copilot:    return false
            case .codex:      return true
            }
        }

        var codexConfigURL: URL? {
            guard case .codex = self else { return nil }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/config.toml")
        }

        fileprivate func commandString(for path: String) -> String {
            switch self {
            case .claudeCode:
                // Always shell-quote so paths with spaces survive (e.g. if
                // the user moves `~/.claude/hooks/` into a directory with
                // whitespace). `currentlyInSync` byte-compares the
                // generated command, so this also makes the on-disk shape
                // canonical regardless of dogfood gate.
                let quoted = shellQuote(path)
                var prefixes: [String] = []
                // #36 dogfood gate: when the user has flipped
                // `enableInlineReplyKey` (via `defaults write` or the
                // Settings panel) and reinstalls hooks, every Claude
                // hook command picks up the env var. Only the `Stop`
                // event reads it (PayloadBuilder → `HookPlan.inlineReplyEnabled`),
                // but leaving it on the others is harmless and keeps
                // the install diff to a single command-string accessor.
                if dynamicIslandUserDefaults.bool(forKey: enableInlineReplyKey) {
                    prefixes.append("CC_ISLAND_INLINE_REPLY=1")
                }
                // #41: Stop reply long-poll horizon. Always emitted so
                // `currentlyInSync` byte-compare matches a fresh install
                // — same value on disk and in memory.
                let stopTimeout = positiveDouble(
                    dynamicIslandUserDefaults,
                    forKey: stopReplyTimeoutKey,
                    default: StopReplyTimeoutSeconds
                )
                prefixes.append("CC_ISLAND_STOP_TIMEOUT=\(formatStopTimeout(stopTimeout))")
                return "\(prefixes.joined(separator: " ")) \(quoted)"
            case .copilot:
                return path
            case .codex:
                return "ISLAND_SOURCE=codex \(shellQuote(path))"
            }
        }

        fileprivate var events: [(name: String, matcher: String, timeout: Int)] {
            switch self {
            case .claudeCode:
                return [
                    ("PreToolUse",         "",                                         5),
                    ("PostToolUse",        "Bash|Edit|Write",                          5),
                    ("PostToolUseFailure", "",                                         5),
                    ("PermissionRequest",  "Bash|Edit|Write|MultiEdit|NotebookEdit",  30),
                    ("PermissionDenied",   "",                                         5),
                    ("Notification",       "",                                         5),
                    // Stop long-polls `/response` for the user's Stop reply
                    // timeout setting (#41) when the user has a reply UI
                    // (#20 quick replies or #36 inline text). Claude Code
                    // SIGKILLs hooks at the registered timeout, so the
                    // entry must outlive the long-poll horizon. +5 s buffer
                    // for round-trip. Derived from the same UserDefault the
                    // env injection reads, so settings.json command and
                    // entry timeout move together on each install.
                    ("Stop", "", Int(ceil(positiveDouble(
                        dynamicIslandUserDefaults,
                        forKey: stopReplyTimeoutKey,
                        default: StopReplyTimeoutSeconds
                    ) + 5))),
                    ("StopFailure",        "",                                         5),
                    ("SubagentStart",      "",                                         5),
                    ("SubagentStop",       "",                                         5),
                    ("UserPromptSubmit",   "",                                         5),
                    ("SessionStart",       "",                                         5),
                    ("SessionEnd",         "",                                         5),
                    ("PreCompact",         "",                                         5),
                    ("PostCompact",        "",                                         5),
                ]
            case .copilot:
                // camelCase event names, per docs.github.com/en/copilot/.../cloud-agent/use-hooks
                return [
                    ("preToolUse",          "", 5),
                    ("postToolUse",         "", 5),
                    ("userPromptSubmitted", "", 5),
                    ("sessionStart",        "", 5),
                    ("sessionEnd",          "", 5),
                    ("errorOccurred",       "", 5),
                ]
            case .codex:
                return [
                    ("SessionStart",      "startup|resume", 5),
                    ("PreToolUse",        "Bash",           5),
                    ("PermissionRequest", "Bash",          30),
                    ("PostToolUse",       "Bash",           5),
                    ("UserPromptSubmit",  "",               5),
                    ("Stop",              "",              30),
                ]
            }
        }
    }

    // MARK: - Public API

    static func install(target: Target) -> Result {
        guard let source = locateHookScript() else {
            return .skipped("island-hook binary not found in app bundle")
        }
        do {
            try deployHookScript(from: source, to: target.deployedHookURL)
            // Clean up the legacy .sh hook from before v1.5 if it's lying around.
            let legacy = target.deployedHookURL.appendingPathExtension("sh")
            try? FileManager.default.removeItem(at: legacy)
            try writeSettings(target: target, shouldHaveHooks: true)
            if case .codex = target {
                try ensureCodexHooksFeatureEnabled()
            }
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func syncIfOutdated(target: Target) -> Result {
        currentlyInSync(target: target) ? .alreadyCurrent : install(target: target)
    }

    static func uninstall(target: Target) -> Result {
        let hadSomething = anyOurEntryExists(target: target)
            || FileManager.default.fileExists(atPath: target.deployedHookURL.path)
        do {
            try writeSettings(target: target, shouldHaveHooks: false)
            try? FileManager.default.removeItem(at: target.deployedHookURL)
            return hadSomething ? .removed : .notInstalled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func hasExistingInstall(target: Target) -> Bool {
        anyOurEntryExists(target: target)
            || FileManager.default.fileExists(atPath: target.deployedHookURL.path)
    }

    // MARK: - Source resolution

    /// Locates the bundled `island-hook` binary that we deploy into the user's
    /// hook directories. Falls back to the dev-build location alongside the
    /// running executable for un-bundled builds.
    private static func locateHookScript() -> URL? {
        if let url = Bundle.main.url(forResource: "island-hook", withExtension: nil),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let exe = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let dir = exe.deletingLastPathComponent()
        let candidates = [
            dir.appendingPathComponent("island-hook"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Detects content drift between the bundled source script and the deployed copy.
    /// If we can't locate a source (dev-build edge case), assume in sync to avoid
    /// triggering an unfixable redeploy loop.
    private static func deployedScriptMatchesSource(target: Target) -> Bool {
        guard let source = locateHookScript() else { return true }
        guard let deployed = try? Data(contentsOf: target.deployedHookURL),
              let bundled  = try? Data(contentsOf: source) else { return false }
        return deployed == bundled
    }

    private static func deployHookScript(from source: URL, to dest: URL) throws {
        let data = try Data(contentsOf: source)
        try AtomicFileWriter.write(
            data,
            to: dest,
            backupExisting: false,
            posixPermissions: 0o755
        )
    }

    // MARK: - Settings manipulation

    private static func currentlyInSync(target: Target) -> Bool {
        guard FileManager.default.fileExists(atPath: target.deployedHookURL.path) else { return false }
        guard deployedScriptMatchesSource(target: target) else { return false }
        guard let data = try? Data(contentsOf: target.settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        let command = target.commandString(for: target.deployedHookURL.path)

        for (event, matcher, timeout) in target.events {
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            let found = entries.contains { entry in
                entryMatches(entry, target: target, matcher: matcher, command: command, timeout: timeout)
            }
            if !found { return false }
        }

        if case .codex = target, !codexHooksFeatureEnabled() {
            return false
        }

        // Reject stale DI entries still pointing at other paths.
        for (_, value) in hooks {
            for entry in (value as? [[String: Any]] ?? []) {
                for cmd in commandsIn(entry: entry, target: target) {
                    if isOurs(commandPath: cmd), cmd != command { return false }
                }
            }
        }
        return true
    }

    private static func anyOurEntryExists(target: Target) -> Bool {
        guard let data = try? Data(contentsOf: target.settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            for entry in (value as? [[String: Any]] ?? []) {
                if commandsIn(entry: entry, target: target).contains(where: isOurs(commandPath:)) {
                    return true
                }
            }
        }
        return false
    }

    /// Extracts the hook command path(s) from an entry, accounting for the
    /// target's schema (Claude Code: nested "hooks" array with "command";
    /// Copilot: flat entry with "bash").
    private static func commandsIn(entry: [String: Any], target: Target) -> [String] {
        switch target {
        case .claudeCode:
            return (entry["hooks"] as? [[String: Any]] ?? [])
                .compactMap { $0["command"] as? String }
        case .copilot:
            return [entry["bash"] as? String].compactMap { $0 }
        case .codex:
            return (entry["hooks"] as? [[String: Any]] ?? [])
                .compactMap { $0["command"] as? String }
        }
    }

    private static func entryMatches(
        _ entry: [String: Any], target: Target,
        matcher: String, command: String, timeout: Int
    ) -> Bool {
        switch target {
        case .claudeCode:
            guard entry["matcher"] as? String == matcher,
                  let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { h in
                (h["command"] as? String) == command && (h["timeout"] as? Int) == timeout
            }
        case .copilot:
            return (entry["bash"] as? String) == command
                && (entry["timeoutSec"] as? Int) == timeout
        case .codex:
            let matchesEverything = matcher.isEmpty
            let entryMatcher = entry["matcher"] as? String
            guard matchesEverything ? (entryMatcher == nil || entryMatcher == "") : (entryMatcher == matcher),
                  let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { h in
                (h["command"] as? String) == command && (h["timeout"] as? Int) == timeout
            }
        }
    }

    private static func isOurs(commandPath: String) -> Bool {
        let markers = ["dynamic-island-hook", "island-hook.sh", "claude-hook.sh", "DynamicIsland"]
        return markers.contains { commandPath.contains($0) }
    }

    struct SettingsParseError: LocalizedError {
        let path: String
        var errorDescription: String? {
            "\(path) exists but is not valid JSON — refusing to overwrite. Fix or remove the file and retry."
        }
    }

    /// Rewrite settings file, preserving entries from other tools. Refuses to
    /// proceed if the existing file is unreadable JSON.
    private static func writeSettings(target: Target, shouldHaveHooks: Bool) throws {
        let url = target.settingsURL
        let fingerprint = try AtomicFileWriter.fingerprint(at: url)
        var root: [String: Any] = [:]
        if fingerprint.exists {
            let data = try Data(contentsOf: url)
            if data.isEmpty {
                root = [:]
            } else {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SettingsParseError(path: url.path)
                }
                root = json
            }
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Strip any existing Dynamic Island entries.
        for key in Array(hooks.keys) {
            var entries = hooks[key] as? [[String: Any]] ?? []
            entries.removeAll { entry in
                commandsIn(entry: entry, target: target).contains(where: isOurs(commandPath:))
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = entries
            }
        }

        if shouldHaveHooks {
            let command = target.commandString(for: target.deployedHookURL.path)
            for (event, matcher, timeout) in target.events {
                var entries = hooks[event] as? [[String: Any]] ?? []
                entries.append(newEntry(target: target, matcher: matcher, command: command, timeout: timeout))
                hooks[event] = entries
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        // Copilot requires a top-level schema version field.
        if case .copilot = target, shouldHaveHooks {
            root["version"] = 1
        }

        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try AtomicFileWriter.write(data, to: url, expectedFingerprint: fingerprint)
    }

    private static func newEntry(
        target: Target, matcher: String, command: String, timeout: Int
    ) -> [String: Any] {
        switch target {
        case .claudeCode:
            return [
                "matcher": matcher,
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": timeout,
                ]],
            ]
        case .copilot:
            return [
                "type": "command",
                "bash": command,
                "timeoutSec": timeout,
            ]
        case .codex:
            var entry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": timeout,
                ]],
            ]
            if !matcher.isEmpty {
                entry["matcher"] = matcher
            }
            return entry
        }
    }

    // MARK: - Codex config.toml

    private static func codexHooksFeatureEnabled() -> Bool {
        guard let url = Target.codex.codexConfigURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        return tomlBoolValue(for: "codex_hooks", inSection: "features", content: content) == true
    }

    private static func ensureCodexHooksFeatureEnabled() throws {
        guard let url = Target.codex.codexConfigURL else { return }
        let fingerprint = try AtomicFileWriter.fingerprint(at: url)
        let existing: String
        if fingerprint.exists {
            existing = try String(contentsOf: url, encoding: .utf8)
        } else {
            existing = ""
        }
        let updated = setTomlBool(true, for: "codex_hooks", inSection: "features", content: existing)

        try AtomicFileWriter.write(
            Data(updated.utf8),
            to: url,
            expectedFingerprint: fingerprint
        )
    }

    private static func tomlBoolValue(
        for key: String,
        inSection section: String,
        content: String
    ) -> Bool? {
        var currentSection: String?
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                continue
            }
            guard currentSection == section else { continue }
            let bare = stripTomlComment(from: line)
            guard let eq = bare.firstIndex(of: "=") else { continue }
            let lhs = bare[..<eq].trimmingCharacters(in: .whitespaces)
            guard lhs == key else { continue }
            let rhs = bare[bare.index(after: eq)...].trimmingCharacters(in: .whitespaces).lowercased()
            if rhs == "true" { return true }
            if rhs == "false" { return false }
        }
        return nil
    }

    private static func setTomlBool(
        _ value: Bool,
        for key: String,
        inSection section: String,
        content: String
    ) -> String {
        let lineValue = "\(key) = \(value ? "true" : "false")"
        if content.isEmpty {
            return "[\(section)]\n\(lineValue)\n"
        }

        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sectionStart: Int?
        var sectionEnd = lines.count

        for (idx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "[\(section)]" {
                sectionStart = idx
                sectionEnd = lines.count
                for next in (idx + 1)..<lines.count {
                    let nextTrimmed = lines[next].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix("[") && nextTrimmed.hasSuffix("]") {
                        sectionEnd = next
                        break
                    }
                }
                break
            }
        }

        if let sectionStart {
            for idx in (sectionStart + 1)..<sectionEnd {
                let stripped = stripTomlComment(from: lines[idx].trimmingCharacters(in: .whitespaces))
                guard let eq = stripped.firstIndex(of: "=") else { continue }
                let lhs = stripped[..<eq].trimmingCharacters(in: .whitespaces)
                if lhs == key {
                    lines[idx] = lineValue
                    return lines.joined(separator: "\n")
                }
            }
            lines.insert(lineValue, at: sectionStart + 1)
            return lines.joined(separator: "\n")
        }

        var updated = content
        if !updated.hasSuffix("\n") { updated += "\n" }
        updated += "\n[\(section)]\n\(lineValue)\n"
        return updated
    }

    private static func stripTomlComment(from line: String) -> String {
        guard let idx = line.firstIndex(of: "#") else { return line }
        return String(line[..<idx]).trimmingCharacters(in: .whitespaces)
    }

    private static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
