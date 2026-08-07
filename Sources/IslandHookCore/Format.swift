import Foundation

/// Truncate a string to `max` characters, appending an ellipsis if trimmed.
public func truncate(_ s: String, _ max: Int) -> String {
    s.count > max ? String(s.prefix(max)) + "…" : s
}

/// POSIX-style basename — last path component.
public func basename(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

/// Trim a multi-line string to the first `maxLines` lines, each truncated
/// to `maxChars`, each prefixed by `prefix`. Appends "  (+K more)" if lines
/// were dropped. Empty string in → empty string out.
public func diffLines(
    _ text: String,
    prefix: String,
    maxLines: Int = 5,
    maxChars: Int = 80
) -> String {
    if text.isEmpty { return "" }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var out: [String] = []
    for line in lines.prefix(maxLines) {
        let trimmed = line.count > maxChars ? String(line.prefix(maxChars)) + "…" : line
        out.append(prefix + trimmed)
    }
    if lines.count > maxLines {
        out.append("  (+\(lines.count - maxLines) more)")
    }
    return out.joined(separator: "\n")
}

/// Build a "- old / + new" preview from two multi-line strings. Either side
/// can be empty — result is empty only if both are.
public func buildEditDiff(old: String, new: String) -> String {
    var parts: [String] = []
    if !old.isEmpty { parts.append(diffLines(old, prefix: "- ")) }
    if !new.isEmpty { parts.append(diffLines(new, prefix: "+ ")) }
    return parts.joined(separator: "\n")
}

/// File paths declared by an `apply_patch` command, in patch order.
public func applyPatchFilePaths(_ patch: String) -> [String] {
    let markers = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
    return patch.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
        let line = String(raw)
        guard let marker = markers.first(where: { line.hasPrefix($0) }) else { return nil }
        let path = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }
}

/// Compact, color-friendly preview for Codex's `apply_patch` tool input.
/// Wrapper lines are removed, file markers become `@@ filename`, and long
/// patches are capped so one tool event cannot make the expanded island huge.
public func buildApplyPatchPreview(
    _ patch: String,
    maxLines: Int = 12,
    maxChars: Int = 100
) -> String {
    guard !patch.isEmpty else { return "" }
    let wrappers = Set(["*** Begin Patch", "*** End Patch"])
    let markers = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
    let normalized = patch.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> String? in
        let line = String(raw)
        if wrappers.contains(line) { return nil }
        if let marker = markers.first(where: { line.hasPrefix($0) }) {
            let path = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return "@@ \(path)"
        }
        return line.count > maxChars ? String(line.prefix(maxChars)) + "…" : line
    }

    var preview = Array(normalized.prefix(maxLines))
    if normalized.count > maxLines {
        preview.append("  (+\(normalized.count - maxLines) more)")
    }
    return preview.joined(separator: "\n")
}
