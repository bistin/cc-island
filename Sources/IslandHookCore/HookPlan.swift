import Foundation

/// Result of parsing a hook payload: source, normalized event/tool names,
/// project labels, and pre-extracted fields needed by payload builders.
public struct HookPlan {
    public let payload: [String: Any]
    public let source: String          // "claude" | "copilot" | "codex"
    public let event: String            // normalized PascalCase event name
    public let tool: String             // normalized tool name
    public let cwd: String
    public let project: String
    public let displayProject: String   // project OR "↳ agent_type" for subagents
    public let agentId: String?
    public let agentType: String?
    public let toolInput: [String: Any]
    public let copilotToolArgs: [String: Any]
    public let cpError: String?         // Copilot .error.message for Error events
    /// True when the hook process was launched with
    /// `CC_ISLAND_INLINE_REPLY=1`. Drives whether `buildStopPayload`
    /// surfaces a `freeform_replyable: true` for non-yes/no Stop
    /// questions (#36 dogfood gate). The matching app-side flag is
    /// `UserDefaults.enableInlineReply`; both must be set.
    public let inlineReplyEnabled: Bool

    public init(
        payload: [String: Any], source: String, event: String, tool: String,
        cwd: String, project: String, displayProject: String,
        agentId: String?, agentType: String?,
        toolInput: [String: Any], copilotToolArgs: [String: Any],
        cpError: String?,
        inlineReplyEnabled: Bool = false
    ) {
        self.payload = payload
        self.source = source
        self.event = event
        self.tool = tool
        self.cwd = cwd
        self.project = project
        self.displayProject = displayProject
        self.agentId = agentId
        self.agentType = agentType
        self.toolInput = toolInput
        self.copilotToolArgs = copilotToolArgs
        self.cpError = cpError
        self.inlineReplyEnabled = inlineReplyEnabled
    }
}

/// Parse a raw hook payload into a `HookPlan`, returning nil if the payload
/// doesn't match any routable shape. Pure — no I/O.
public func parseHookPlan(payload: [String: Any], env: [String: String] = [:]) -> HookPlan? {
    // SOURCE drives the project color:
    //   claude  → warm orange    copilot → GitHub violet    codex → OpenAI green
    // Override via ISLAND_SOURCE env var (Codex hook script should set this).
    var source = env["ISLAND_SOURCE"] ?? ""

    let ccEvent = payload["hook_event_name"] as? String
    let cpTool = payload["toolName"] as? String
    let cpPrompt = payload["prompt"] as? String
    let cpSource = payload["source"] as? String
    let cpReason = payload["reason"] as? String
    let cpError = (payload["error"] as? [String: Any])?["message"] as? String

    var event = ""
    var tool = ""

    if let ccEvent = ccEvent {
        event = ccEvent
        tool = (payload["tool_name"] as? String) ?? ""
        // First-letter casing distinguishes Claude (PascalCase) from Copilot (camelCase).
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
        } else { return nil }
    }

    // Copilot uses camelCase event names — normalize to PascalCase.
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

    let cwd = (payload["cwd"] as? String) ?? ""
    let project = cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
    let agentId = payload["agent_id"] as? String
    let agentType = payload["agent_type"] as? String
    let hasAgent = !(agentId ?? "").isEmpty && !(agentType ?? "").isEmpty
    let displayProject = hasAgent ? "↳ \(agentType!)" : project

    let toolInput = (payload["tool_input"] as? [String: Any]) ?? [:]

    let copilotToolArgs: [String: Any] = {
        guard let s = payload["toolArgs"] as? String,
              let data = s.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }()

    return HookPlan(
        payload: payload, source: source, event: event, tool: tool,
        cwd: cwd, project: project, displayProject: displayProject,
        agentId: agentId, agentType: agentType,
        toolInput: toolInput, copilotToolArgs: copilotToolArgs,
        cpError: cpError,
        inlineReplyEnabled: env["CC_ISLAND_INLINE_REPLY"] == "1"
    )
}

extension HookPlan {
    /// Whether this PreToolUse should cache its payload to /tmp for the next
    /// PermissionRequest to read (FIFO context correlation).
    public var shouldCachePreToolUse: Bool {
        ["Edit", "Write", "Bash", "MultiEdit", "NotebookEdit"].contains(tool)
    }

    /// Adds project / agent / source fields common to every event.
    public func decorate(_ base: [String: Any]) -> [String: Any] {
        var p = base
        if !displayProject.isEmpty { p["project"] = displayProject }
        if let id = agentId, !id.isEmpty { p["agent_id"] = id }
        if let t = agentType, !t.isEmpty { p["agent_type"] = t }
        if !source.isEmpty { p["source"] = source }
        // Forward Claude Code's session UUID so the island can tell two
        // main sessions in the same project apart — needed for the
        // "user resolved on the terminal side" detection (#31 follow-up).
        if let sid = payload["session_id"] as? String, !sid.isEmpty {
            p["session_id"] = sid
        }
        return p
    }

    public func toolInputString(_ key: String) -> String {
        (toolInput[key] as? String) ?? ""
    }

    /// File path — tries Claude's `tool_input.file_path` then Copilot's
    /// `toolArgs.{file_path|path|filePath}`.
    public var filePath: String {
        let f = toolInputString("file_path")
        if !f.isEmpty { return f }
        for key in ["file_path", "path", "filePath"] {
            if let v = copilotToolArgs[key] as? String, !v.isEmpty { return v }
        }
        return ""
    }

    /// Bash command — tries Claude's `tool_input.command` then Copilot's
    /// `toolArgs.command`.
    public var command: String {
        let c = toolInputString("command")
        if !c.isEmpty { return c }
        return (copilotToolArgs["command"] as? String) ?? ""
    }
}
