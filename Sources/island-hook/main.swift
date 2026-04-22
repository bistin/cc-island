// island-hook — universal hook binary that replaces hooks/island-hook.sh.
// Reads a Claude Code / Copilot / Codex hook payload from stdin, formats an
// island event, and POSTs it to the running Dynamic Island app on
// 127.0.0.1:9423. Foundation-only so the deployed binary stays small and
// the user no longer needs `jq` installed.
//
// PermissionRequest is the only event that produces stdout: it long-polls
// /response and emits the JSON allow/deny decision Claude Code expects.

import Foundation

// MARK: - Constants

let port = ProcessInfo.processInfo.environment["DYNAMIC_ISLAND_PORT"]
    .flatMap(Int.init) ?? 9423
let eventURL = URL(string: "http://127.0.0.1:\(port)/event")!
let responseURL = URL(string: "http://127.0.0.1:\(port)/response")!

// MARK: - Read stdin

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard !inputData.isEmpty,
      let jsonAny = try? JSONSerialization.jsonObject(with: inputData),
      let payload = jsonAny as? [String: Any] else {
    exit(0)
}

// MARK: - Source & event detection
//
// SOURCE drives the project color:
//   claude  → warm orange    copilot → GitHub violet    codex → OpenAI green
// Override via ISLAND_SOURCE env var (Codex hook script should set this).

var source = ProcessInfo.processInfo.environment["ISLAND_SOURCE"] ?? ""

let ccEvent = payload["hook_event_name"] as? String
let cpTool = payload["toolName"] as? String
let cpPrompt = payload["prompt"] as? String
let cpSource = payload["source"] as? String
let cpReason = payload["reason"] as? String
let cpError: String? = (payload["error"] as? [String: Any])?["message"] as? String

var event = ""
var tool = ""

if let ccEvent = ccEvent {
    event = ccEvent
    tool = (payload["tool_name"] as? String) ?? ""
    // First-letter casing distinguishes Claude (PascalCase) from Copilot CLI (camelCase).
    if source.isEmpty {
        source = (ccEvent.first?.isUppercase ?? true) ? "claude" : "copilot"
    }
} else {
    if source.isEmpty { source = "copilot" }
    if let cpTool = cpTool {
        let resultType = (payload["toolResult"] as? [String: Any])?["resultType"] as? String
        event = (resultType != nil) ? "PostToolUse" : "PreToolUse"
        tool = cpTool
    } else if cpError != nil { event = "Error"
    } else if cpReason != nil { event = "Stop"
    } else if cpSource != nil { event = "SessionStart"
    } else if cpPrompt != nil { event = "UserPromptSubmit"
    } else { exit(0) }
}

// Copilot uses camelCase event names — normalize to the PascalCase forms we switch on.
if source == "copilot" {
    let map = [
        "preToolUse":          "PreToolUse",
        "postToolUse":         "PostToolUse",
        "userPromptSubmitted": "UserPromptSubmit",
        "sessionStart":        "SessionStart",
        "sessionEnd":          "SessionEnd",
        "errorOccurred":       "Error",
    ]
    if let mapped = map[event] { event = mapped }
}

// Copilot tool names are lowercase; normalize.
let toolNameMap = [
    "edit": "Edit", "create": "Write", "view": "Read", "bash": "Bash",
    "grep": "Grep", "glob": "Glob", "agent": "Agent",
]
tool = toolNameMap[tool] ?? tool

// MARK: - Project / subagent labels

let cwd = (payload["cwd"] as? String) ?? ""
let project = cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
let agentId = payload["agent_id"] as? String
let agentType = payload["agent_type"] as? String
let hasAgent = !(agentId ?? "").isEmpty && !(agentType ?? "").isEmpty
let displayProject: String = hasAgent ? "↳ \(agentType!)" : project

// MARK: - Helpers

func send(_ extra: [String: Any]) {
    var p = extra
    if !displayProject.isEmpty { p["project"] = displayProject }
    if let id = agentId, !id.isEmpty { p["agent_id"] = id }
    if let t  = agentType, !t.isEmpty { p["agent_type"] = t }
    if !source.isEmpty { p["source"] = source }

    guard let body = try? JSONSerialization.data(withJSONObject: p) else { return }

    var req = URLRequest(url: eventURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    req.timeoutInterval = 3

    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
    _ = sem.wait(timeout: .now() + 3)
}

/// Synchronous GET /response with timeout — returns "allow", "deny", or "timeout".
func longPollResponse(timeoutSeconds: TimeInterval) -> String {
    var req = URLRequest(url: responseURL)
    req.timeoutInterval = timeoutSeconds + 1

    var decision = "timeout"
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["decision"] as? String else { return }
        decision = d
    }.resume()
    _ = sem.wait(timeout: .now() + timeoutSeconds + 2)
    return decision
}

func truncate(_ s: String, _ max: Int) -> String {
    s.count > max ? String(s.prefix(max)) + "…" : s
}

func basename(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

/// Trim a multi-line string to first N lines, each truncated to ~maxChars,
/// each prefixed by `prefix`. Appends "(+K more)" if lines were dropped.
func diffLines(_ text: String, prefix: String, maxLines: Int = 5, maxChars: Int = 80) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var out: [String] = []
    for line in lines.prefix(maxLines) {
        out.append(prefix + (line.count > maxChars ? String(line.prefix(maxChars)) + "…" : line))
    }
    if lines.count > maxLines {
        out.append("  (+\(lines.count - maxLines) more)")
    }
    return out.joined(separator: "\n")
}

func buildEditDiff(old: String, new: String) -> String {
    var parts: [String] = []
    if !old.isEmpty { parts.append(diffLines(old, prefix: "- ")) }
    if !new.isEmpty { parts.append(diffLines(new, prefix: "+ ")) }
    return parts.joined(separator: "\n")
}

// MARK: - Tool input extraction (handles both Claude Code and Copilot shapes)

let toolInput: [String: Any] = (payload["tool_input"] as? [String: Any]) ?? [:]

let copilotToolArgs: [String: Any] = {
    guard let s = payload["toolArgs"] as? String,
          let data = s.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return dict
}()

func toolInputString(_ key: String) -> String {
    (toolInput[key] as? String) ?? ""
}

func getFile() -> String {
    let f = toolInputString("file_path")
    if !f.isEmpty { return f }
    for key in ["file_path", "path", "filePath"] {
        if let v = copilotToolArgs[key] as? String, !v.isEmpty { return v }
    }
    return ""
}

func getCommand() -> String {
    let c = toolInputString("command")
    if !c.isEmpty { return c }
    return (copilotToolArgs["command"] as? String) ?? ""
}

// MARK: - FIFO context cache for permission diff preview

let contextFile = "/tmp/di_pretool_\(project.isEmpty ? "default" : project).json"

func writeContextCache() {
    try? inputData.write(to: URL(fileURLWithPath: contextFile))
}

func readCachedToolInput() -> (toolName: String, input: [String: Any])? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: contextFile)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    let name = (json["tool_name"] as? String) ?? ""
    let input = (json["tool_input"] as? [String: Any]) ?? [:]
    return (name, input)
}

// MARK: - Event handlers

func handlePreToolUse() {
    switch tool {
    case "Edit":
        let fname = basename(getFile())
        var oldStr = toolInputString("old_string")
        var newStr = toolInputString("new_string")
        // MultiEdit fallback — sniff first edit
        if oldStr.isEmpty && newStr.isEmpty,
           let edits = toolInput["edits"] as? [[String: Any]],
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
        send(p)

    case "Write":
        let fname = basename(getFile())
        var content = toolInputString("content")
        if content.isEmpty { content = (copilotToolArgs["content"] as? String) ?? "" }
        var p: [String: Any] = [
            "title": "Writing", "subtitle": fname.isEmpty ? "file" : fname,
            "style": "claude", "duration": 3,
        ]
        if !content.isEmpty { p["detail"] = diffLines(content, prefix: "+ ") }
        send(p)

    case "Read":
        let fname = basename(getFile())
        send([
            "title": "Reading", "subtitle": fname.isEmpty ? "file" : fname,
            "style": "claude", "duration": 2,
        ])

    case "Bash":
        let cmd = getCommand()
        let desc = toolInputString("description")
        let display = truncate(desc.isEmpty ? cmd : desc, 35)
        send([
            "title": "Terminal", "subtitle": display,
            "style": "claude", "duration": 3,
        ])

    case "Grep":
        var pattern = toolInputString("pattern")
        if pattern.isEmpty { pattern = (copilotToolArgs["pattern"] as? String) ?? "" }
        send([
            "title": "Searching", "subtitle": truncate(pattern, 30),
            "style": "claude", "duration": 2,
        ])

    case "Glob":
        var pattern = toolInputString("pattern")
        if pattern.isEmpty { pattern = (copilotToolArgs["pattern"] as? String) ?? "" }
        send([
            "title": "Finding files", "subtitle": pattern,
            "style": "claude", "duration": 2,
        ])

    case "Agent":
        let desc = toolInputString("description")
        let agentTy = toolInputString("subagent_type").isEmpty ? "agent" : toolInputString("subagent_type")
        send([
            "title": "Agent", "subtitle": truncate(desc.isEmpty ? agentTy : desc, 35),
            "style": "claude", "duration": 3,
        ])

    default:
        let display = tool.replacingOccurrences(of: #"^mcp__[^_]*__"#, with: "", options: .regularExpression)
        send([
            "title": display, "style": "claude", "duration": 2,
        ])
    }

    // Cache for FIFO correlation with the next PermissionRequest.
    if ["Edit", "Write", "Bash", "MultiEdit", "NotebookEdit"].contains(tool) {
        writeContextCache()
    }
}

func handlePostToolUse() {
    switch tool {
    case "Edit", "Write":
        let fname = basename(getFile())
        send([
            "title": "Saved", "subtitle": fname.isEmpty ? "file" : fname,
            "style": "success", "duration": 1.5,
        ])
    default:
        break
    }
}

func handlePostToolUseFailure() {
    let err = (payload["tool_error"] as? String) ?? (payload["error"] as? String) ?? ""
    let trimmed = String(err.prefix(60))
    send([
        "title": "Tool failed",
        "subtitle": trimmed.isEmpty ? tool : trimmed,
        "style": "error", "duration": 5,
    ])
}

func handlePermissionDenied() {
    let toolName = (payload["tool_name"] as? String) ?? "tool"
    let reason = String(((payload["denial_reason"] as? String) ?? "").prefix(60))
    send([
        "title": "Denied",
        "subtitle": reason.isEmpty ? toolName : reason,
        "style": "warning", "duration": 4,
    ])
}

func handleNotification() {
    let notifType = (payload["notification_type"] as? String) ?? ""
    if notifType == "permission_prompt" { return } // PermissionRequest handles real buttons
    let msg = (payload["message"] as? String) ?? "Notification"
    send([
        "title": "Claude Code", "subtitle": truncate(msg, 45), "style": "reminder",
    ])
}

func handlePermissionRequest() -> Never {
    let toolName = (payload["tool_name"] as? String) ?? "tool"
    var toolDetail = String(
        (toolInputString("command").isEmpty ? toolInputString("file_path") : toolInputString("command"))
            .prefix(40)
    )

    // FIFO correlation: enrich dialog with diff/content from preceding PreToolUse
    var diff = ""
    if let cached = readCachedToolInput(), cached.toolName == toolName {
        let input = cached.input
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
                let cmd = (input["description"] as? String) ?? (input["command"] as? String) ?? ""
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
    send(p)

    let decision = longPollResponse(timeoutSeconds: 25)
    switch decision {
    case "allow":
        print(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
    case "deny":
        print(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Dynamic Island"}}}"#)
    default:
        break // timeout: silently defer to Claude Code's normal flow
    }
    exit(0)
}

func handleStop() {
    send(["type": "thinking_stop"])
    let lastMsg = (payload["last_assistant_message"] as? String) ?? ""
    let tail = String(lastMsg.suffix(200))
    if tail.range(of: #"[?？]\s*$"#, options: .regularExpression) != nil {
        send(["title": "Waiting", "subtitle": "Your turn", "style": "reminder"])
    } else {
        send(["title": "Done", "style": "success", "duration": 3])
    }
}

func handleStopFailure() {
    send(["type": "thinking_stop"])
    let err = String(((payload["stop_error"] as? String) ?? "").prefix(60))
    send([
        "title": "Error", "subtitle": err.isEmpty ? "API error" : err,
        "style": "error", "duration": 6,
    ])
}

func handleError() {
    send(["type": "thinking_stop"])
    send([
        "title": "Error", "subtitle": truncate(cpError ?? "", 35),
        "style": "error", "duration": 5,
    ])
}

func handleSubagentStart() {
    let agentTy = (payload["agent_type"] as? String) ?? "agent"
    send([
        "title": "Agent", "subtitle": agentTy, "style": "claude", "duration": 3,
    ])
}

func handleSubagentStop() {
    let agentTy = (payload["agent_type"] as? String) ?? "agent"
    send(["type": "subagent_stop"])
    send([
        "title": "Agent done", "subtitle": agentTy, "style": "success", "duration": 2,
    ])
}

func handleSessionStart() {
    let src = (payload["source"] as? String) ?? "startup"
    send(["title": "Session", "subtitle": src, "style": "info", "duration": 2])
}

func handleSessionEnd() {
    send(["type": "thinking_stop"])
}

func handlePreCompact() {
    send(["title": "Compacting", "subtitle": "context", "style": "info", "duration": 2])
}

func handlePostCompact() {
    send(["title": "Compacted", "style": "success", "duration": 2])
}

func handleUserPromptSubmit() {
    send(["type": "thinking_start"])
}

// MARK: - Dispatch

switch event {
case "PreToolUse":         handlePreToolUse()
case "PostToolUse":        handlePostToolUse()
case "PostToolUseFailure": handlePostToolUseFailure()
case "PermissionRequest":  handlePermissionRequest()
case "PermissionDenied":   handlePermissionDenied()
case "Notification":       handleNotification()
case "Stop":               handleStop()
case "StopFailure":        handleStopFailure()
case "Error":              handleError()
case "SubagentStart":      handleSubagentStart()
case "SubagentStop":       handleSubagentStop()
case "SessionStart":       handleSessionStart()
case "SessionEnd":         handleSessionEnd()
case "PreCompact":         handlePreCompact()
case "PostCompact":        handlePostCompact()
case "UserPromptSubmit":   handleUserPromptSubmit()
default: exit(0)
}
exit(0)
