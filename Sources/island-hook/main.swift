// island-hook — universal hook binary that replaces hooks/island-hook.sh.
// Reads a Claude Code / Copilot / Codex hook payload from stdin, formats an
// island event (via IslandHookCore), and POSTs it to the running Dynamic
// Island app on 127.0.0.1:9423.
//
// PermissionRequest and Stop are the two events that produce stdout. PermissionRequest long-polls
// /response and emits the JSON allow/deny decision the active provider expects.

import Foundation
import IslandHookCore

let port = ProcessInfo.processInfo.environment["DYNAMIC_ISLAND_PORT"]
    .flatMap(Int.init) ?? 9423
let eventURL = URL(string: "http://127.0.0.1:\(port)/event")!
let responseURL = URL(string: "http://127.0.0.1:\(port)/response")!

/// One UUID per hook invocation — the IslandEvent it produces and any
/// subsequent `/response` poll share it so a late click from a previous
/// event can't get harvested by this hook (issue #31).
let eventID = UUID().uuidString.lowercased()

// MARK: - Parse stdin

let inputData = FileHandle.standardInput.readDataToEndOfFile()
// Resolve the parent process's controlling TTY before parse so it rides
// through `decorate` into every payload — see `HookPlan.tty`.
let detectedTTY = detectControllingTTY()
guard !inputData.isEmpty,
      let jsonAny = try? JSONSerialization.jsonObject(with: inputData),
      let payload = jsonAny as? [String: Any],
      let plan = parseHookPlan(
        payload: payload,
        env: ProcessInfo.processInfo.environment,
        tty: detectedTTY,
        // Only this process can see it: the hook runs inside the pane, the app
        // does not. Without it a server started with `tmux -L name` is invisible.
        tmuxSocket: tmuxSocketPath(fromTMUXEnv: ProcessInfo.processInfo.environment["TMUX"])
      )
else { exit(0) }

// MARK: - I/O helpers

func send(_ body: [String: Any]) {
    var enriched = body
    enriched["event_id"] = eventID
    guard let data = try? JSONSerialization.data(withJSONObject: enriched) else { return }
    var req = URLRequest(url: eventURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    req.timeoutInterval = 3

    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
    _ = sem.wait(timeout: .now() + 3)
}

struct PermissionDecision {
    var behavior: String
    var rule: (toolName: String, ruleContent: String)?
}

func longPollResponse(timeoutSeconds: TimeInterval) -> PermissionDecision {
    // Scope the poll to this hook's event so a parked decision from an
    // earlier (timed-out) event can't satisfy us — see issue #31.
    var components = URLComponents(url: responseURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "event_id", value: eventID)]
    var req = URLRequest(url: components.url!)
    req.timeoutInterval = timeoutSeconds + 1
    var decision = PermissionDecision(behavior: "timeout", rule: nil)
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        // Backwards-compatible: older server versions returned
        // `{"decision": "allow"}`. Newer ones return
        // `{"behavior": "allow", "rule": {...}?}`.
        let behavior = (json["behavior"] as? String) ?? (json["decision"] as? String) ?? "timeout"
        decision.behavior = behavior
        if let rule = json["rule"] as? [String: Any],
           let toolName = rule["toolName"] as? String,
           let ruleContent = rule["ruleContent"] as? String {
            decision.rule = (toolName: toolName, ruleContent: ruleContent)
        }
    }.resume()
    _ = sem.wait(timeout: .now() + timeoutSeconds + 2)
    return decision
}

// MARK: - FIFO context cache

// Per-user cache instead of `/tmp/di_pretool_<project>.json`. Keyed
// by `session_id` (Claude) → `agent-<id>-<project>` → `<project>` →
// `default`, so two parallel sessions in the same project don't
// overwrite each other's context. See `IslandHookCore.PreToolCache`.
let contextURL = preToolCacheURL(key: preToolCacheKey(plan: plan))

func writeContextCache() {
    try? FileManager.default.createDirectory(
        at: contextURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    // .atomic so a process crash mid-write can't leave a truncated
    // JSON for the next PermissionRequest to read. Single-slot cache,
    // worst case the previous payload survives — never a half one.
    try? inputData.write(to: contextURL, options: [.atomic])
}

func readCachedToolInput() -> (toolName: String, input: [String: Any])? {
    guard let data = try? Data(contentsOf: contextURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    let name = (json["tool_name"] as? String) ?? ""
    let input = (json["tool_input"] as? [String: Any]) ?? [:]
    return (name, input)
}

// MARK: - Dispatch

switch plan.event {
case "PreToolUse":
    send(buildPreToolUsePayload(plan))
    if plan.shouldCachePreToolUse { writeContextCache() }

case "PostToolUse":
    if let body = buildPostToolUsePayload(plan) { send(body) }

case "PostToolUseFailure":
    send(buildPostToolUseFailurePayload(plan))

case "PermissionDenied":
    send(buildPermissionDeniedPayload(plan))

case "Notification":
    if let body = buildNotificationPayload(plan) { send(body) }

case "PermissionRequest":
    let cached = readCachedToolInput()
    let body = buildPermissionRequestPayload(
        plan,
        cachedInput: cached?.input,
        cachedToolName: cached?.toolName
    )
    send(body)

    // Horizon sourced from `CC_ISLAND_PERMISSION_TIMEOUT` env (parsed into
    // `plan.permissionTimeoutSeconds`, default 300 s). The matching
    // settings.json PermissionRequest entry timeout outlives this by +5 s
    // so Claude Code doesn't SIGKILL the hook mid-poll.
    let decision = longPollResponse(timeoutSeconds: plan.permissionTimeoutSeconds)
    switch decision.behavior {
    case "allow":
        if let rule = decision.rule {
            // Claude Code persists the pattern to localSettings (project scope)
            // — matches the "Yes, and don't ask again for: <pattern>" option
            // from its own interactive prompt.
            let payload: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedPermissions": [[
                            "type": "addRules",
                            "rules": [[
                                "toolName": rule.toolName,
                                "ruleContent": rule.ruleContent,
                            ]],
                            "behavior": "allow",
                            "destination": "localSettings",
                        ] as [String: Any]],
                    ] as [String: Any],
                ],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
               let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }
        } else {
            print(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
        }
    case "deny":
        print(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from CLI Island"}}}"#)
    default: break
    }
    exit(0)

case "Stop":
    send(["type": "thinking_stop"])
    let stopPayload = buildStopPayload(plan)
    send(stopPayload)
    // #20 Phase 1: when the payload offers quick-reply buttons, long-poll
    // for the user's choice and emit `decision: block + reason: <label>`
    // so Claude treats the label as the next instruction. Timeout drops
    // back to Claude Code's default Stop behavior silently.
    //
    // #20 Phase 2 (#36): same long-poll path when the payload signals
    // a free-form reply is enabled. The text typed into the island's
    // TextField rides the same channel as a quick-reply label.
    let hasQuickReplies = stopPayload["quick_replies"] is [String]
    let hasFreeformReply = (stopPayload["freeform_replyable"] as? Bool) == true
    if hasQuickReplies || hasFreeformReply {
        // #41: horizon sourced from `CC_ISLAND_STOP_TIMEOUT` env (parsed
        // into `plan.stopReplyTimeoutSeconds` with default fallback).
        let decision = longPollResponse(timeoutSeconds: plan.stopReplyTimeoutSeconds)
        if decision.behavior != "timeout" && !decision.behavior.isEmpty {
            print(encodeStopBlockResponse(reason: decision.behavior))
        }
    }

case "StopFailure":
    send(["type": "thinking_stop"])
    send(buildStopFailurePayload(plan))

case "Error":
    send(["type": "thinking_stop"])
    send(buildErrorPayload(plan))

case "SubagentStart":
    send(buildSubagentStartPayload(plan))

case "SubagentStop":
    // The agent id was missing here, which made the whole message a no-op: the app's handler
    // reads it to know which row to close and returned early without one. Nothing ever removed
    // a subagent row, and the 90-second sweep was the only thing that did.
    // Omitted rather than blanked when absent, matching how `decorate` writes every other
    // optional field. Sending "" would have the server call removeSession(id: "") — harmless,
    // because no row has that id, but it is one character from the shape of the bug this
    // message had in the first place.
    var close: [String: Any] = ["type": "subagent_stop"]
    if let id = plan.payload["agent_id"] as? String, !id.isEmpty { close["agent_id"] = id }
    send(close)
    send(buildSubagentStopPayload(plan))

case "SessionStart":
    send(buildSessionStartPayload(plan))

case "SessionEnd":
    send(["type": "thinking_stop"])

case "PreCompact":
    send(buildPreCompactPayload(plan))

case "PostCompact":
    send(buildPostCompactPayload(plan))

case "UserPromptSubmit":
    send(["type": "thinking_start", "source": plan.source])

default: break
}

exit(0)
