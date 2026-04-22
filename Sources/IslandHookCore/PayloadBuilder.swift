import Foundation

/// Build the island event payload for a PreToolUse. Decorated with
/// project/agent/source already — callers can POST directly.
public func buildPreToolUsePayload(_ plan: HookPlan) -> [String: Any] {
    switch plan.tool {
    case "Edit":
        let fname = basename(plan.filePath)
        var oldStr = plan.toolInputString("old_string")
        var newStr = plan.toolInputString("new_string")
        // MultiEdit fallback — sniff first edit
        if oldStr.isEmpty && newStr.isEmpty,
           let edits = plan.toolInput["edits"] as? [[String: Any]],
           let first = edits.first {
            oldStr = (first["old_string"] as? String) ?? ""
            newStr = (first["new_string"] as? String) ?? ""
        }
        let diff = buildEditDiff(old: oldStr, new: newStr)
        var p: [String: Any] = [
            "title": "Editing", "subtitle": fname.isEmpty ? "file" : fname,
            "style": "claude", "duration": 3,
        ]
        if !diff.isEmpty { p["detail"] = diff }
        return plan.decorate(p)

    case "Write":
        let fname = basename(plan.filePath)
        var content = plan.toolInputString("content")
        if content.isEmpty { content = (plan.copilotToolArgs["content"] as? String) ?? "" }
        var p: [String: Any] = [
            "title": "Writing", "subtitle": fname.isEmpty ? "file" : fname,
            "style": "claude", "duration": 3,
        ]
        if !content.isEmpty { p["detail"] = diffLines(content, prefix: "+ ") }
        return plan.decorate(p)

    case "Read":
        let fname = basename(plan.filePath)
        return plan.decorate([
            "title": "Reading", "subtitle": fname.isEmpty ? "file" : fname,
            "style": "claude", "duration": 2,
        ])

    case "Bash":
        let cmd = plan.command
        let desc = plan.toolInputString("description")
        let display = truncate(desc.isEmpty ? cmd : desc, 35)
        return plan.decorate([
            "title": "Terminal", "subtitle": display,
            "style": "claude", "duration": 3,
        ])

    case "Grep":
        var pattern = plan.toolInputString("pattern")
        if pattern.isEmpty { pattern = (plan.copilotToolArgs["pattern"] as? String) ?? "" }
        return plan.decorate([
            "title": "Searching", "subtitle": truncate(pattern, 30),
            "style": "claude", "duration": 2,
        ])

    case "Glob":
        var pattern = plan.toolInputString("pattern")
        if pattern.isEmpty { pattern = (plan.copilotToolArgs["pattern"] as? String) ?? "" }
        return plan.decorate([
            "title": "Finding files", "subtitle": pattern,
            "style": "claude", "duration": 2,
        ])

    case "Agent":
        let desc = plan.toolInputString("description")
        let agentTy = plan.toolInputString("subagent_type").isEmpty
            ? "agent"
            : plan.toolInputString("subagent_type")
        return plan.decorate([
            "title": "Agent", "subtitle": truncate(desc.isEmpty ? agentTy : desc, 35),
            "style": "claude", "duration": 3,
        ])

    default:
        let display = plan.tool.replacingOccurrences(
            of: #"^mcp__[^_]*__"#, with: "", options: .regularExpression
        )
        return plan.decorate([
            "title": display, "style": "claude", "duration": 2,
        ])
    }
}

/// Returns nil if nothing to emit for this PostToolUse.
public func buildPostToolUsePayload(_ plan: HookPlan) -> [String: Any]? {
    switch plan.tool {
    case "Edit", "Write":
        let fname = basename(plan.filePath)
        return plan.decorate([
            "title": "Saved", "subtitle": fname.isEmpty ? "file" : fname,
            "style": "success", "duration": 1.5,
        ])
    default:
        return nil
    }
}

public func buildPostToolUseFailurePayload(_ plan: HookPlan) -> [String: Any] {
    let err = (plan.payload["tool_error"] as? String)
        ?? (plan.payload["error"] as? String) ?? ""
    let trimmed = String(err.prefix(60))
    return plan.decorate([
        "title": "Tool failed",
        "subtitle": trimmed.isEmpty ? plan.tool : trimmed,
        "style": "error", "duration": 5,
    ])
}

public func buildPermissionDeniedPayload(_ plan: HookPlan) -> [String: Any] {
    let toolName = (plan.payload["tool_name"] as? String) ?? "tool"
    let reason = String(((plan.payload["denial_reason"] as? String) ?? "").prefix(60))
    return plan.decorate([
        "title": "Denied",
        "subtitle": reason.isEmpty ? toolName : reason,
        "style": "warning", "duration": 4,
    ])
}

/// Returns nil when this is a permission_prompt Notification that we want
/// to ignore (the real PermissionRequest hook will show Allow/Deny).
public func buildNotificationPayload(_ plan: HookPlan) -> [String: Any]? {
    let notifType = (plan.payload["notification_type"] as? String) ?? ""
    if notifType == "permission_prompt" { return nil }
    let msg = (plan.payload["message"] as? String) ?? "Notification"
    return plan.decorate([
        "title": "Claude Code", "subtitle": truncate(msg, 45), "style": "reminder",
    ])
}

/// Build the PermissionRequest dialog payload. If cached PreToolUse input
/// is provided and matches the tool, enriches the detail with a diff or
/// content preview.
public func buildPermissionRequestPayload(
    _ plan: HookPlan,
    cachedInput: [String: Any]? = nil,
    cachedToolName: String? = nil
) -> [String: Any] {
    let toolName = (plan.payload["tool_name"] as? String) ?? "tool"
    var toolDetail = String(
        (plan.toolInputString("command").isEmpty
            ? plan.toolInputString("file_path")
            : plan.toolInputString("command")
        ).prefix(40)
    )

    var diff = ""
    if let input = cachedInput, cachedToolName == toolName {
        switch toolName {
        case "Edit", "MultiEdit":
            var oldStr = (input["old_string"] as? String) ?? ""
            var newStr = (input["new_string"] as? String) ?? ""
            if oldStr.isEmpty && newStr.isEmpty,
               let edits = input["edits"] as? [[String: Any]], let first = edits.first {
                oldStr = (first["old_string"] as? String) ?? ""
                newStr = (first["new_string"] as? String) ?? ""
            }
            diff = buildEditDiff(old: oldStr, new: newStr)
        case "Write":
            let content = (input["content"] as? String) ?? ""
            if !content.isEmpty { diff = diffLines(content, prefix: "+ ") }
        case "Bash":
            if toolDetail.isEmpty {
                let cmd = (input["description"] as? String)
                    ?? (input["command"] as? String) ?? ""
                toolDetail = String(cmd.prefix(40))
            }
        default: break
        }
    }

    var p: [String: Any] = [
        "title": "Permission",
        "subtitle": "\(toolName): \(toolDetail)",
        "style": "action",
    ]
    if !diff.isEmpty { p["detail"] = diff }
    return plan.decorate(p)
}

public func buildStopPayload(_ plan: HookPlan) -> [String: Any] {
    let lastMsg = (plan.payload["last_assistant_message"] as? String) ?? ""
    let tail = String(lastMsg.suffix(200))
    if tail.range(of: #"[?？]\s*$"#, options: .regularExpression) != nil {
        let question = extractLastQuestion(from: lastMsg)
        var p: [String: Any] = [
            "title": "Waiting",
            "subtitle": truncate(question.isEmpty ? "Your turn" : question, 50),
            "style": "reminder",
        ]
        if !lastMsg.isEmpty { p["detail"] = lastMsg }
        return plan.decorate(p)
    } else {
        return plan.decorate([
            "title": "Done", "style": "success", "duration": 3,
        ])
    }
}

/// Pulls the final sentence from an assistant message — typically the question
/// Claude is asking. Splits at sentence terminators (`.`, `!`, `?`, fullwidth
/// `。`, `！`, `？`) and newlines so a multi-sentence single-line message gets
/// the trailing sentence isolated rather than the whole message.
public func extractLastQuestion(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }

    let terminators: Set<Character> = [".", "!", "?", "。", "！", "？", "\n"]

    // Skip the trailing terminator so the reverse walk doesn't treat it as
    // the sentence separator (we want the PRIOR one).
    var idx = trimmed.endIndex
    if let lastChar = trimmed.last, terminators.contains(lastChar) {
        idx = trimmed.index(before: idx)
    }

    while idx > trimmed.startIndex {
        let prev = trimmed.index(before: idx)
        if terminators.contains(trimmed[prev]) {
            var startIdx = idx
            while startIdx < trimmed.endIndex && trimmed[startIdx].isWhitespace {
                startIdx = trimmed.index(after: startIdx)
            }
            return String(trimmed[startIdx...]).trimmingCharacters(in: .whitespaces)
        }
        idx = prev
    }
    return trimmed
}

public func buildStopFailurePayload(_ plan: HookPlan) -> [String: Any] {
    let err = String(((plan.payload["stop_error"] as? String) ?? "").prefix(60))
    return plan.decorate([
        "title": "Error", "subtitle": err.isEmpty ? "API error" : err,
        "style": "error", "duration": 6,
    ])
}

public func buildErrorPayload(_ plan: HookPlan) -> [String: Any] {
    return plan.decorate([
        "title": "Error", "subtitle": truncate(plan.cpError ?? "", 35),
        "style": "error", "duration": 5,
    ])
}

public func buildSubagentStartPayload(_ plan: HookPlan) -> [String: Any] {
    let agentTy = (plan.payload["agent_type"] as? String) ?? "agent"
    return plan.decorate([
        "title": "Agent", "subtitle": agentTy, "style": "claude", "duration": 3,
    ])
}

public func buildSubagentStopPayload(_ plan: HookPlan) -> [String: Any] {
    let agentTy = (plan.payload["agent_type"] as? String) ?? "agent"
    return plan.decorate([
        "title": "Agent done", "subtitle": agentTy, "style": "success", "duration": 2,
    ])
}

public func buildSessionStartPayload(_ plan: HookPlan) -> [String: Any] {
    let src = (plan.payload["source"] as? String) ?? "startup"
    return plan.decorate([
        "title": "Session", "subtitle": src, "style": "info", "duration": 2,
    ])
}

public func buildPreCompactPayload(_ plan: HookPlan) -> [String: Any] {
    return plan.decorate([
        "title": "Compacting", "subtitle": "context", "style": "info", "duration": 2,
    ])
}

public func buildPostCompactPayload(_ plan: HookPlan) -> [String: Any] {
    return plan.decorate([
        "title": "Compacted", "style": "success", "duration": 2,
    ])
}
