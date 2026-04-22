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
