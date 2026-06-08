import Foundation

/// Parsed quick-reply payload from a `Stop` event payload's
/// `quick_replies`. Capped at 3 entries / 20 characters per label so
/// the button row fits inside the notch's expanded view (~445 pt) and
/// the capsule (~420 pt). Returns `nil` for non-array, empty array,
/// or arrays whose only entries are non-strings.
public func decodeQuickReplies(from raw: Any?) -> [String]? {
    guard let array = raw as? [Any] else { return nil }
    let labels = array
        .compactMap { $0 as? String }
        .map { String($0.prefix(20)) }
        .prefix(3)
    return labels.isEmpty ? nil : Array(labels)
}

/// Whether the event payload's `freeform_replyable` flag is
/// *explicitly* `true` (`Bool == true`). Anything else — missing,
/// numeric, string, false — returns false. Strict to keep the
/// "free-form text field only when the hook says so" invariant
/// described in `LocalServer.processEvent`.
public func decodeFreeformReplyable(from raw: Any?) -> Bool {
    (raw as? Bool) == true
}

/// Strings carrying a permission-rule suggestion forwarded from the
/// `PermissionRequest` hook (#28's "Always allow" feature). Returns
/// nil if either field is missing or non-string. The caller is
/// responsible for wrapping these into the `PermissionRuleSuggestion`
/// struct (which currently lives in the SwiftUI-coupled
/// `DynamicIsland` module, hence the tuple here).
public func decodeSuggestedRuleFields(from json: [String: Any]) -> (toolName: String, ruleContent: String)? {
    guard let rule = json["suggested_rule"] as? [String: Any],
          let toolName = rule["toolName"] as? String,
          let ruleContent = rule["ruleContent"] as? String else {
        return nil
    }
    return (toolName, ruleContent)
}

/// Strict allow-list for the `tty` field on event payloads. Returns the
/// path verbatim only when it matches `/dev/ttys<digits>` or
/// `/dev/pts/<digits>` — the two shapes macOS / Linux assign to
/// pseudo-terminals. Anything else (relative paths, traversal,
/// unrelated `/dev/` device nodes, non-strings) returns nil.
///
/// The value is interpolated into AppleScript source at click time
/// (see `TerminalActivator`), so a permissive decoder would expose a
/// shell-style injection surface to anyone able to POST `/event`. Keep
/// this list narrow.
public func decodeTTY(from raw: Any?) -> String? {
    guard let s = raw as? String, !s.isEmpty, s.count <= 64 else { return nil }
    let pattern = #"^/dev/(ttys[0-9]+|pts/[0-9]+)$"#
    guard s.range(of: pattern, options: .regularExpression) != nil else { return nil }
    return s
}
