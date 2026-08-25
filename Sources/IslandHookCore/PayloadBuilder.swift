import Foundation

/// The tools whose "execution" *is* a person answering.
///
/// Everything else the island shows is something that happened; these are something that has not
/// happened yet, and will not until somebody looks. That makes them the only events where every
/// second of not being noticed costs something — measured across the transcripts on one machine,
/// 58 of these were answered at a median of 71 seconds and a maximum of **10.9 hours**. Ten hours
/// is not deliberation, it is nobody knowing they were being asked.
///
/// **The waiting is visible only through the hook, and that was measured rather than assumed.**
/// The transcript writes an assistant `tool_use` and its `tool_result` together *after* the tool
/// returns, so a pending question never reaches disk — see `DynamicIslandCore.TranscriptState`.
/// `PreToolUse`, though, fires before the tool runs, which for these tools means before the person
/// answers. Confirmed by capturing the POST from a live session: it arrived **18.3 seconds before
/// the answer did**, while the menu was still on screen.
///
/// One list, used by both halves: the payload builder below and the `PostToolUse` matcher
/// `HookInstaller` registers. Two lists would agree for exactly as long as nobody edited either,
/// and the failure mode is the bad one — a waiting event with nothing to clear it.
public enum InteractiveTools {
    public static let names = ["AskUserQuestion", "ExitPlanMode"]

    /// The names as Claude Code's `settings.json` wants them.
    public static var matcher: String { names.joined(separator: "|") }

    public static func contains(_ tool: String) -> Bool { names.contains(tool) }
}


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

    case "apply_patch":
        let patch = plan.toolInputString("command")
        let paths = applyPatchFilePaths(patch)
        let firstName = paths.first.map(basename) ?? "files"
        let subtitle = paths.count > 1 ? "\(firstName) +\(paths.count - 1)" : firstName
        var payload: [String: Any] = [
            "title": "Editing", "subtitle": subtitle,
            "style": "claude", "duration": 3,
        ]
        let preview = buildApplyPatchPreview(patch)
        if !preview.isEmpty { payload["detail"] = preview }
        return plan.decorate(payload)

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

    case "AskUserQuestion":
        // `reminder`: pulsing, and deliberately without buttons. The answer is a menu in the
        // terminal, and a second place to answer it would be a second source of truth.
        var p: [String: Any] = [
            "title": "Waiting for you",
            "subtitle": truncate(firstQuestion(plan).isEmpty ? "a question" : firstQuestion(plan), 35),
            "style": "reminder",
            // Set rather than left to the style's default: this payload crosses a version
            // boundary, and an older island that does not infer it would dismiss the one event
            // that must not be dismissed.
            "persistent": true,
        ]
        let detail = questionDetail(plan)
        if !detail.isEmpty { p["detail"] = detail }
        return plan.decorate(p)

    case "ExitPlanMode":
        let plan_ = plan.toolInputString("plan")
        var p: [String: Any] = [
            "title": "Plan ready",
            "subtitle": truncate(planHeadline(plan_).isEmpty ? "waiting to start" : planHeadline(plan_), 35),
            "style": "reminder",
            "persistent": true,
        ]
        if !plan_.isEmpty { p["detail"] = String(plan_.prefix(600)) }
        return plan.decorate(p)

    default:
        let display = plan.tool.replacingOccurrences(
            of: #"^mcp__[^_]*__"#, with: "", options: .regularExpression
        )
        return plan.decorate([
            "title": display, "style": "claude", "duration": 2,
        ])
    }
}

/// The first question being asked, or "" when the payload does not carry one.
func firstQuestion(_ plan: HookPlan) -> String {
    guard let questions = plan.toolInput["questions"] as? [[String: Any]],
          let first = questions.first,
          let text = first["question"] as? String else { return "" }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The questions and what can be picked, for the expanded view.
func questionDetail(_ plan: HookPlan) -> String {
    guard let questions = plan.toolInput["questions"] as? [[String: Any]] else { return "" }
    var lines: [String] = []
    for question in questions {
        if let text = question["question"] as? String, !text.isEmpty { lines.append(text) }
        guard let options = question["options"] as? [[String: Any]] else { continue }
        for option in options {
            if let label = option["label"] as? String, !label.isEmpty { lines.append("  · \(label)") }
        }
    }
    return lines.joined(separator: "\n")
}

/// The first line of a plan that says something, with any markdown heading marker taken off.
///
/// Plans open with a `# Title` far more often than not, and `#` in a 35-character ear is a
/// character spent saying nothing.
func planHeadline(_ plan: String) -> String {
    for line in plan.split(separator: "\n", omittingEmptySubsequences: false) {
        var text = line.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return text }
    }
    return ""
}

/// Returns nil if nothing to emit for this PostToolUse.
public func buildPostToolUsePayload(_ plan: HookPlan) -> [String: Any]? {
    // The answer arrived. This exists to *replace* the persistent waiting event more than to say
    // anything itself — a "waiting for you" left on the island after the answer is worse than
    // never having shown it, because it teaches the reader to ignore the one state that matters.
    if InteractiveTools.contains(plan.tool) {
        return plan.decorate([
            "title": "Answered", "style": "success", "duration": 1.5,
        ])
    }
    switch plan.tool {
    case "Edit", "Write", "apply_patch":
        let fname = basename(plan.filePath)
        let applyPatchName = applyPatchFilePaths(plan.toolInputString("command")).first.map(basename)
        return plan.decorate([
            "title": "Saved", "subtitle": applyPatchName ?? (fname.isEmpty ? "file" : fname),
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

/// A rule string that approximates Claude Code's own "don't ask again"
/// suggestion. The caller forwards this through the PermissionRequest
/// payload so the UI can offer an "Always allow" button; when the user
/// picks it, the hook emits `updatedPermissions` with `localSettings`
/// destination matching Claude's built-in behaviour.
///
/// Heuristic, kept deliberately conservative:
/// - Bash: first two space-separated tokens + ` *` (matches the
///   "glab api *" / "git status *" style Claude shows in its own prompt).
/// - Other tools: nil for now — pattern shape differs per tool
///   (`Edit(**/*.swift)` etc.) and we'd rather not offer a wrong rule.
public func suggestPermissionRule(toolName: String, toolInput: [String: Any]) -> (toolName: String, ruleContent: String)? {
    switch toolName {
    case "Bash":
        let cmd = (toolInput["command"] as? String) ?? ""
        let tokens = cmd.split(separator: " ").prefix(2).map(String.init)
        guard !tokens.isEmpty else { return nil }
        return (toolName: "Bash", ruleContent: tokens.joined(separator: " ") + " *")
    default:
        return nil
    }
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
    let displayToolName = toolName == "apply_patch" ? "Edit" : toolName
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

    if toolName == "apply_patch" {
        let effectiveInput = (cachedToolName == toolName ? cachedInput : nil) ?? plan.toolInput
        let patch = (effectiveInput["command"] as? String) ?? ""
        let paths = applyPatchFilePaths(patch)
        toolDetail = paths.first.map(basename) ?? "files"
        diff = buildApplyPatchPreview(patch)
    }

    var p: [String: Any] = [
        "title": "Permission",
        "subtitle": "\(displayToolName): \(toolDetail)",
        "style": "action",
    ]
    if !diff.isEmpty { p["detail"] = diff }
    // Suggest an "always allow" rule when we have enough signal. The UI
    // uses this to offer a third button; when chosen, the hook echoes the
    // pattern back to Claude Code via `updatedPermissions`.
    let effectiveInput = (cachedToolName == toolName ? cachedInput : nil) ?? plan.toolInput
    if plan.source == "claude",
       let rule = suggestPermissionRule(toolName: toolName, toolInput: effectiveInput) {
        p["suggested_rule"] = [
            "toolName": rule.toolName,
            "ruleContent": rule.ruleContent,
        ]
    }
    return plan.decorate(p)
}

public func buildStopPayload(_ plan: HookPlan) -> [String: Any] {
    let lastMsg = (plan.payload["last_assistant_message"] as? String) ?? ""
    if containsQuestion(lastMsg) {
        let question = extractLastQuestion(from: lastMsg)
        var p: [String: Any] = [
            "title": "Waiting",
            "subtitle": truncate(question.isEmpty ? "Your turn" : question, 50),
            "style": "reminder",
        ]
        if !lastMsg.isEmpty { p["detail"] = lastMsg }
        // Phase 1 of #20: when we recognise a yes/no shape, surface
        // quick-reply buttons. Reading the buttons in island-hook decides
        // whether to long-poll for a reply and emit `decision:block`.
        if let options = extractYesNoOptions(from: lastMsg) {
            p["quick_replies"] = options
            p["persistent"] = true
        } else if plan.inlineReplyEnabled {
            // Phase 2 of #20 (#36): question without a yes/no shape +
            // dogfood gate enabled → app renders a free-form TextField.
            // Hook side will long-poll on this signal, same way as
            // quick_replies. Default-off (no env, no flag): omit the
            // field, hook does not long-poll, behaviour unchanged.
            p["freeform_replyable"] = true
            p["persistent"] = true
        }
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

/// An agent finishing.
///
/// **`closes_agent` is the important field.** This payload carries the agent's id like every
/// other, and the app routes anything with an id into that agent's row — so the event announcing
/// that an agent had finished was *re-creating the row it had just been asked to remove*, and
/// refreshing its idle clock while doing it. Every finished subagent then sat in the tree for the
/// full sweep interval, which is how a workflow spawning agents in a loop fills the panel with
/// things that are no longer running.
///
/// The flag says "show this, then close the channel", which is one message with one meaning
/// rather than two that disagree.
public func buildSubagentStopPayload(_ plan: HookPlan) -> [String: Any] {
    let agentTy = (plan.payload["agent_type"] as? String) ?? "agent"
    return plan.decorate([
        "title": "Agent done", "subtitle": agentTy, "style": "success", "duration": 2,
        "closes_agent": true,
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
