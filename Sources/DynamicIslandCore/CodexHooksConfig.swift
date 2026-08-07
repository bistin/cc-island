import Foundation

/// Returns whether Codex lifecycle hooks are enabled for a user config.
///
/// Hooks are enabled by default when `config.toml`, `[features]`, or the
/// feature key is absent. `hooks` is the canonical key; `codex_hooks` is
/// accepted only as a legacy fallback so existing installs keep working.
public func codexHooksFeatureEnabled(in content: String?) -> Bool {
    guard let content else { return true }
    if let value = tomlBoolValue(for: "hooks", inSection: "features", content: content) {
        return value
    }
    if let legacy = tomlBoolValue(
        for: "codex_hooks", inSection: "features", content: content
    ) {
        return legacy
    }
    return true
}

/// Enables Codex hooks using the canonical `[features].hooks` key.
///
/// An absent key is left absent because Codex enables hooks by default. A
/// deprecated `codex_hooks` assignment is migrated in place. If both keys
/// exist, the canonical key wins and the deprecated duplicate is removed.
public func enablingCodexHooks(in content: String) -> String {
    guard !content.isEmpty else { return content }

    var lines = content.split(
        separator: "\n", omittingEmptySubsequences: false
    ).map(String.init)
    guard let range = tomlSectionRange(named: "features", in: lines) else {
        return content
    }

    let canonicalIndex = range.first { tomlAssignmentKey(in: lines[$0]) == "hooks" }
    let legacyIndex = range.first { tomlAssignmentKey(in: lines[$0]) == "codex_hooks" }

    if let canonicalIndex {
        lines[canonicalIndex] = replacingTomlBool(
            in: lines[canonicalIndex], key: "hooks", value: true
        )
        if let legacyIndex {
            lines.remove(at: legacyIndex)
        }
    } else if let legacyIndex {
        lines[legacyIndex] = replacingTomlBool(
            in: lines[legacyIndex], key: "hooks", value: true
        )
    }

    return lines.joined(separator: "\n")
}

private func tomlBoolValue(
    for key: String,
    inSection section: String,
    content: String
) -> Bool? {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let range = tomlSectionRange(named: section, in: lines) else { return nil }
    for index in range where tomlAssignmentKey(in: lines[index]) == key {
        let uncommented = stripTomlComment(from: lines[index])
        guard let equals = uncommented.firstIndex(of: "=") else { continue }
        let value = uncommented[uncommented.index(after: equals)...]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if value == "true" { return true }
        if value == "false" { return false }
    }
    return nil
}

private func tomlSectionRange(named section: String, in lines: [String]) -> Range<Int>? {
    guard let start = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "[\(section)]"
    }) else { return nil }

    let first = start + 1
    let end = lines[first...].firstIndex(where: {
        let line = $0.trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("[") && line.hasSuffix("]")
    }) ?? lines.endIndex
    return first..<end
}

private func tomlAssignmentKey(in line: String) -> String? {
    let uncommented = stripTomlComment(from: line)
    guard let equals = uncommented.firstIndex(of: "=") else { return nil }
    return uncommented[..<equals].trimmingCharacters(in: .whitespaces)
}

private func replacingTomlBool(in line: String, key: String, value: Bool) -> String {
    let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
    let comment = line.firstIndex(of: "#").map { " " + line[$0...].trimmingCharacters(in: .whitespaces) }
        ?? ""
    return "\(indentation)\(key) = \(value ? "true" : "false")\(comment)"
}

private func stripTomlComment(from line: String) -> String {
    guard let index = line.firstIndex(of: "#") else { return line }
    return String(line[..<index]).trimmingCharacters(in: .whitespaces)
}
