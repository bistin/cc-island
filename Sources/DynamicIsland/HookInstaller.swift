import Foundation

/// Deploys island-hook.sh and registers hook events for either Claude Code
/// (~/.claude/settings.json) or GitHub Copilot (~/.copilot/hooks/hooks.json).
///
/// The two formats differ:
///   Claude Code: { "matcher": "pattern", "hooks": [{ type, command, timeout }] }
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
        case copilot

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .copilot:    return "Copilot"
            }
        }

        var deployedHookURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeCode: return home.appendingPathComponent(".claude/hooks/dynamic-island-hook.sh")
            case .copilot:    return home.appendingPathComponent(".copilot/hooks/dynamic-island-hook.sh")
            }
        }

        var settingsURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeCode: return home.appendingPathComponent(".claude/settings.json")
            case .copilot:    return home.appendingPathComponent(".copilot/hooks/hooks.json")
            }
        }

        var usesMatcher: Bool { self == .claudeCode }

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
                    ("Stop",               "",                                         5),
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
                return [
                    ("PreToolUse",       "", 5),
                    ("PostToolUse",      "", 5),
                    ("UserPromptSubmit", "", 5),
                    ("Stop",             "", 5),
                    ("SessionStart",     "", 5),
                    ("SubagentStart",    "", 5),
                    ("SubagentStop",     "", 5),
                ]
            }
        }
    }

    // MARK: - Public API

    static func install(target: Target) -> Result {
        guard let source = locateHookScript() else {
            return .skipped("island-hook.sh not found in app bundle")
        }
        do {
            try deployHookScript(from: source, to: target.deployedHookURL)
            try writeSettings(target: target, shouldHaveHooks: true)
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

    // MARK: - Source resolution

    private static func locateHookScript() -> URL? {
        if let url = Bundle.main.url(forResource: "island-hook", withExtension: "sh"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let exe = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let candidates = [
            exe.deletingLastPathComponent().appendingPathComponent("island-hook.sh"),
            exe.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("hooks/island-hook.sh"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func deployHookScript(from source: URL, to dest: URL) throws {
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    // MARK: - Settings manipulation

    private static func currentlyInSync(target: Target) -> Bool {
        guard FileManager.default.fileExists(atPath: target.deployedHookURL.path) else { return false }
        guard let data = try? Data(contentsOf: target.settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        let path = target.deployedHookURL.path

        for (event, matcher, timeout) in target.events {
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            let found = entries.contains { entry in
                entryMatches(entry, target: target, matcher: matcher, command: path, timeout: timeout)
            }
            if !found { return false }
        }

        // Reject stale DI entries still pointing at other paths.
        for (_, value) in hooks {
            for entry in (value as? [[String: Any]] ?? []) {
                for cmd in commandsIn(entry: entry, target: target) {
                    if isOurs(commandPath: cmd), cmd != path { return false }
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
    /// target's schema (nested "hooks" array for Claude, flat for Copilot).
    private static func commandsIn(entry: [String: Any], target: Target) -> [String] {
        if target.usesMatcher {
            return (entry["hooks"] as? [[String: Any]] ?? [])
                .compactMap { $0["command"] as? String }
        } else {
            return [entry["command"] as? String].compactMap { $0 }
        }
    }

    private static func entryMatches(
        _ entry: [String: Any], target: Target,
        matcher: String, command: String, timeout: Int
    ) -> Bool {
        if target.usesMatcher {
            guard entry["matcher"] as? String == matcher,
                  let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { h in
                (h["command"] as? String) == command && (h["timeout"] as? Int) == timeout
            }
        } else {
            return (entry["command"] as? String) == command
                && (entry["timeout"] as? Int) == timeout
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
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SettingsParseError(path: url.path)
            }
            root = json
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
            let path = target.deployedHookURL.path
            for (event, matcher, timeout) in target.events {
                var entries = hooks[event] as? [[String: Any]] ?? []
                entries.append(newEntry(target: target, matcher: matcher, command: path, timeout: timeout))
                hooks[event] = entries
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private static func newEntry(
        target: Target, matcher: String, command: String, timeout: Int
    ) -> [String: Any] {
        if target.usesMatcher {
            return [
                "matcher": matcher,
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": timeout,
                ]],
            ]
        } else {
            return [
                "type": "command",
                "command": command,
                "timeout": timeout,
            ]
        }
    }
}
