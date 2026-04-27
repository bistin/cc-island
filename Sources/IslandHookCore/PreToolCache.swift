import Foundation

/// Single-slot context cache that lets `PermissionRequest` enrich its
/// dialog with the `tool_input` from the immediately preceding
/// `PreToolUse` (FIFO context correlation). Two pure helpers compute
/// the cache *key* and *URL*; actual file I/O lives in `island-hook`.
///
/// Pre-#5x layout was `/tmp/di_pretool_<project>.json` keyed by
/// project basename. `/tmp` is world-readable on a multi-user machine
/// and the path is predictable, so a co-tenant could plant a payload
/// our `PermissionRequest` would happily read. The new home is the
/// per-user `~/Library/Caches/cc-island/pretool/`, which inherits user
/// permissions, plus a stronger key that distinguishes parallel
/// sessions in the same project.

/// Pick a cache filename stem for the current hook invocation.
///
/// Resolution order:
/// 1. `session_id` (Claude Code's session UUID) — most precise.
/// 2. `agent-<agentId>-<sanitised-project>` — for subagent runs that
///    don't carry `session_id` from the host.
/// 3. `<sanitised-project>` — legacy / non-Claude callers.
/// 4. `default` — payload had no project at all.
public func preToolCacheKey(plan: HookPlan) -> String {
    if let sid = plan.sessionID, !sid.isEmpty {
        return sanitiseCacheKey(sid)
    }
    if let agentId = plan.agentId, !agentId.isEmpty {
        return sanitiseCacheKey("agent-\(agentId)-\(plan.project.isEmpty ? "default" : plan.project)")
    }
    if !plan.project.isEmpty {
        return sanitiseCacheKey(plan.project)
    }
    return "default"
}

/// Build the on-disk path for a given cache key. `cachesDirectory`
/// defaults to the user's `~/Library/Caches`; tests pass a temporary
/// directory so they don't touch the real cache.
public func preToolCacheURL(
    key: String,
    cachesDirectory: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)
        .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
) -> URL {
    cachesDirectory
        .appendingPathComponent("cc-island", isDirectory: true)
        .appendingPathComponent("pretool", isDirectory: true)
        .appendingPathComponent("\(key).json")
}

/// Replace any character that's awkward inside a filename (path
/// separators, shell metas, whitespace) with `_`. Pure — no fancy
/// percent-encoding so the resulting filename stays readable for
/// debugging.
public func sanitiseCacheKey(_ raw: String) -> String {
    let unsafe: Set<Character> = ["/", "\\", ":", "?", "<", ">", "|", "*", "\"", " ", "\t", "\n"]
    var out = ""
    out.reserveCapacity(raw.count)
    for ch in raw {
        out.append(unsafe.contains(ch) ? "_" : ch)
    }
    return out.isEmpty ? "default" : out
}
