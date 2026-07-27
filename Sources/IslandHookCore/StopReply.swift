import Foundation

/// How long the Stop hook waits for a reply via the long-poll `/response`
/// endpoint before falling back to Claude Code's default Stop behavior.
/// Issue #20 marks 30 s as a first guess — short enough that Claude Code's
/// internal flow doesn't stall, long enough that a user who briefly tabs
/// away can still react. Tunable as user feedback rolls in.
public let StopReplyTimeoutSeconds: TimeInterval = 30

/// How long the `PermissionRequest` hook waits for the user to tap
/// Allow/Deny on the island before falling back to Claude Code's own
/// permission prompt. Replaces the three scattered hard-coded `25` s
/// values (hook long-poll, `LocalServer` server long-poll, and the
/// `IslandState` expired-dim mirror) with one tunable horizon.
///
/// Default 5 minutes — long enough that the user can step away from the
/// keyboard and still come back to a live Allow/Deny, instead of the old
/// 25 s window that dimmed the buttons before they returned. Sourced from
/// `CC_ISLAND_PERMISSION_TIMEOUT` on the hook side and the
/// `permissionTimeoutSeconds` UserDefault on the app side.
public let PermissionTimeoutSeconds: TimeInterval = 300

/// Returns true if `message` contains a `?` or `？` anywhere — used to
/// decide whether a Stop event should offer reply UI (quick-reply buttons
/// today, inline text field once Phase 2 lands).
///
/// Bias toward showing: `extractLastQuestion` (#9 v1.5.0) only catches the
/// trailing sentence's terminator, missing embedded questions like
/// "你覺得呢？如果不這樣做的話系統可能會有問題". False positives are 1 second
/// of "no buttons appeared, dismiss"; false negatives waste Cmd-Tab effort.
public func containsQuestion(_ message: String) -> Bool {
    return message.contains("?") || message.contains("？")
}

/// Detects yes/no patterns in a Stop event message and returns the labels
/// to render as quick-reply buttons. Returns nil when no patterns match —
/// callers must NOT synthesise a default `["Yes", "No"]` (a wrong rule is
/// worse than no rule, mirrors `suggestPermissionRule` from #28).
///
/// Recognised patterns:
///   - `yes/no` (or `no/yes`, fullwidth `／`, any case) → `["Yes", "No"]`
///   - `y/n` (any case) → `["Yes", "No"]`
///   - `是/否` (or `否/是`, fullwidth `／`) → `["是", "否"]`
public func extractYesNoOptions(from message: String) -> [String]? {
    let opts: NSString.CompareOptions = [.regularExpression, .caseInsensitive]

    if message.range(of: #"\b(yes\s*[/／]\s*no|no\s*[/／]\s*yes)\b"#, options: opts) != nil {
        return ["Yes", "No"]
    }
    if message.range(of: #"\b(y\s*[/／]\s*n|n\s*[/／]\s*y)\b"#, options: opts) != nil {
        return ["Yes", "No"]
    }
    if message.contains("是/否") || message.contains("是／否")
        || message.contains("否/是") || message.contains("否／是") {
        return ["是", "否"]
    }
    return nil
}

/// Builds the JSON body the Stop hook prints to stdout when the user
/// replies through the island. Claude Code receives this as
/// `decision: "block"` + `reason: "<text>"`, treating `reason` as the
/// user's next instruction (per the official hooks docs).
///
/// `JSONSerialization` is the only contract the hook side relies on —
/// see `EncodeStopBlockResponseTests` for the round-trip cases (UTF-8 /
/// emoji / quotes / newlines / 5000-char) that map to the edge cases
/// xero7689 flagged in issue #20.
public func encodeStopBlockResponse(reason: String) -> String {
    let payload: [String: Any] = [
        "decision": "block",
        "reason": reason,
    ]
    guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.withoutEscapingSlashes]),
          let body = String(data: data, encoding: .utf8) else {
        return #"{"decision":"block","reason":""}"#  // Should never trigger
    }
    return body
}
