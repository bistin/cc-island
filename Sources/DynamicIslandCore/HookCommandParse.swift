import Foundation

/// Strip `KEY=value` env prefixes and surrounding shell quotes from a
/// hook `command` string, leaving the bare executable path.
///
/// Settings files store the command as a single string with optional
/// env-var prefixes injected by `HookInstaller.commandString` and the
/// path shell-quoted to survive whitespace. To compare two such strings
/// for "are they pointing at the same binary", we need a canonical
/// form. Examples:
///
///     /Users/foo/.claude/hooks/dynamic-island-hook
///     '/Users/foo/.claude/hooks/dynamic-island-hook'
///     CC_ISLAND_STOP_TIMEOUT=30 '/Users/foo/.claude/hooks/dynamic-island-hook'
///     CC_ISLAND_INLINE_REPLY=1 CC_ISLAND_STOP_TIMEOUT=30 '/Users/foo/.claude/hooks/dynamic-island-hook'
///     ISLAND_SOURCE=codex '/Users/foo/.codex/hooks/dynamic-island-hook'
///
/// All five collapse to the bare path. Pure — no I/O.
public func stripCommandPrefix(_ command: String) -> String {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    // Match a leading sequence of `KEY=value ` pairs. Both KEY and value
    // are non-space; values aren't expected to contain whitespace
    // (they're env vars set by the installer like `1` / `30` / `codex`).
    let envPrefix = #"^(?:[A-Z_][A-Z0-9_]*=\S+\s+)+"#
    let withoutEnv: String
    if let range = trimmed.range(of: envPrefix, options: .regularExpression) {
        withoutEnv = String(trimmed[range.upperBound...])
    } else {
        withoutEnv = trimmed
    }
    return stripQuotes(withoutEnv)
}

/// Strip a single matching pair of leading/trailing `'` or `"` quotes.
private func stripQuotes(_ s: String) -> String {
    guard s.count >= 2 else { return s }
    let first = s.first!
    let last = s.last!
    if (first == "'" && last == "'") || (first == "\"" && last == "\"") {
        return String(s.dropFirst().dropLast())
    }
    return s
}
