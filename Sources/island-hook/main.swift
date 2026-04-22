// island-hook — universal hook binary that replaces hooks/island-hook.sh.
// Reads a Claude Code / Copilot / Codex hook payload from stdin, formats an
// island event (via IslandHookCore), and POSTs it to the running Dynamic
// Island app on 127.0.0.1:9423.
//
// PermissionRequest is the only event that produces stdout: it long-polls
// /response and emits the JSON allow/deny decision Claude Code expects.

import Foundation
import IslandHookCore

let port = ProcessInfo.processInfo.environment["DYNAMIC_ISLAND_PORT"]
    .flatMap(Int.init) ?? 9423
let eventURL = URL(string: "http://127.0.0.1:\(port)/event")!
let responseURL = URL(string: "http://127.0.0.1:\(port)/response")!

// MARK: - Parse stdin

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard !inputData.isEmpty,
      let jsonAny = try? JSONSerialization.jsonObject(with: inputData),
      let payload = jsonAny as? [String: Any],
      let plan = parseHookPlan(payload: payload, env: ProcessInfo.processInfo.environment)
else { exit(0) }

// MARK: - I/O helpers

func send(_ body: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
    var req = URLRequest(url: eventURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    req.timeoutInterval = 3

    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
    _ = sem.wait(timeout: .now() + 3)
}

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

// MARK: - FIFO context cache

let contextFile = "/tmp/di_pretool_\(plan.project.isEmpty ? "default" : plan.project).json"

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

    switch longPollResponse(timeoutSeconds: 25) {
    case "allow":
        print(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
    case "deny":
        print(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Dynamic Island"}}}"#)
    default: break
    }
    exit(0)

case "Stop":
    send(["type": "thinking_stop"])
    send(buildStopPayload(plan))

case "StopFailure":
    send(["type": "thinking_stop"])
    send(buildStopFailurePayload(plan))

case "Error":
    send(["type": "thinking_stop"])
    send(buildErrorPayload(plan))

case "SubagentStart":
    send(buildSubagentStartPayload(plan))

case "SubagentStop":
    send(["type": "subagent_stop"])
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
    send(["type": "thinking_start"])

default: break
}

exit(0)
