import Foundation
import Network
import DynamicIslandCore

/// Lightweight HTTP server that receives Claude Code hook events.
/// Listens on a configurable port (default 9423) for POST /event requests.
///
/// Expected JSON body:
/// ```json
/// {
///   "type": "tool_start" | "tool_end" | "notification" | "stop" | "error" | "custom",
///   "title": "string",
///   "subtitle": "optional string",
///   "detail": "optional string",
///   "style": "info" | "success" | "warning" | "error" | "claude",
///   "duration": 4.0,
///   "progress": 0.0-1.0
/// }
/// ```
/// Encodes the UI's permission decision for the long-polling hook.
/// `rule` is non-nil only when the user chose "Always allow"; the hook
/// forwards it to Claude Code as `updatedPermissions.rules[0]` so the
/// pattern lands in the user's `localSettings`.
struct PermissionDecision {
    let behavior: String                     // "allow" | "deny"
    let rule: PermissionRuleSuggestion?

    var jsonBody: String {
        var parts = ["\"behavior\":\"\(behavior)\""]
        if let rule = rule {
            parts.append(
                "\"rule\":{\"toolName\":\"\(rule.toolName)\",\"ruleContent\":\(Self.encodeJSON(rule.ruleContent))}"
            )
        }
        return "{\(parts.joined(separator: ","))}"
    }

    private static func encodeJSON(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let jsonArr = String(data: data, encoding: .utf8) {
            // Strip "[" and "]" to get just the quoted, escaped string.
            return String(jsonArr.dropFirst().dropLast())
        }
        return "\"\"" // fallback — will not corrupt the envelope
    }
}

class LocalServer {
    let port: UInt16
    private var listener: NWListener?
    private weak var stateManager: IslandStateManager?

    /// Pending permission response — hook script polls this
    private var pendingResponse: PermissionDecision?
    private let responseLock = NSLock()
    private var responseWaiters: [CheckedContinuation<PermissionDecision, Never>] = []

    init(stateManager: IslandStateManager, port: UInt16 = 9423) {
        self.stateManager = stateManager
        self.port = port
    }

    /// Called from UI when user taps Allow/Deny/Always.
    func setResponse(_ behavior: String, rule: PermissionRuleSuggestion? = nil) {
        let decision = PermissionDecision(behavior: behavior, rule: rule)
        responseLock.lock()
        let waiters = responseWaiters
        responseWaiters.removeAll()
        if waiters.isEmpty {
            pendingResponse = decision
        }
        responseLock.unlock()
        for waiter in waiters {
            waiter.resume(returning: decision)
        }
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("[DynamicIsland] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[DynamicIsland] Server listening on port \(self.port)")
            case .failed(let error):
                print("[DynamicIsland] Server failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
    }

    /// Per-connection read buffer cap. Generous enough for any realistic hook
    /// payload (current hook payloads top out ~2 KB) while still bounding the
    /// damage from a misbehaving client.
    private static let maxRequestBytes = 1_048_576 // 1 MiB

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        readRequest(connection: connection, buffer: Data())
    }

    /// Keeps calling `connection.receive` until we have a complete HTTP
    /// request (headers + Content-Length bytes of body), then dispatches.
    ///
    /// Previously the server called `receive` exactly once and assumed the
    /// entire request arrived in that single callback. URLSession (used by
    /// the Swift `island-hook` binary) writes headers and body in separate
    /// syscalls, which the Network framework routinely surfaces as separate
    /// receive callbacks — so the body was being lost. See
    /// `.issues/fix-localserver-partial-read.md`.
    private func readRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error = error {
                print("[DynamicIsland] connection receive error: \(error)")
                connection.cancel()
                return
            }

            var buf = buffer
            if let chunk = chunk { buf.append(chunk) }

            switch HTTPParser.parse(buf, maxTotalBytes: Self.maxRequestBytes) {
            case .needMore:
                if isComplete {
                    // Client hung up mid-request. Nothing to do.
                    connection.cancel()
                    return
                }
                self.readRequest(connection: connection, buffer: buf)

            case .done(let request):
                self.dispatch(connection: connection, request: request)

            case .invalid(let reason):
                print("[DynamicIsland] malformed HTTP request: \(reason)")
                self.sendHTTP(
                    connection,
                    body: Self.errorBody(code: "malformed_request", message: reason),
                    statusCode: "400 Bad Request"
                )

            case .tooLarge:
                // Fail fast: headers + declared Content-Length exceed our cap,
                // or headers alone are pathologically large.
                print("[DynamicIsland] request exceeded \(Self.maxRequestBytes) bytes — rejecting")
                self.sendHTTP(
                    connection,
                    body: Self.errorBody(code: "payload_too_large",
                                         message: "request exceeds \(Self.maxRequestBytes) bytes"),
                    statusCode: "413 Payload Too Large"
                )
            }
        }
    }

    /// Route a fully-parsed HTTP request. Same semantics as the original
    /// `handleConnection` switch — just unblocked from read-loop concerns.
    private func dispatch(connection: NWConnection, request: HTTPRequest) {
        if request.path.hasPrefix("/response") {
            handleResponsePoll(connection)
        } else if request.path.hasPrefix("/event") {
            do {
                guard !request.body.isEmpty else {
                    throw EventError.missingBody
                }
                try processEvent(request.body)
                sendHTTP(connection, body: "{\"status\":\"ok\"}")
            } catch {
                let eventError = error as? EventError
                let code = eventError?.code ?? "internal_error"
                let message = eventError?.message ?? "\(error)"
                print("[DynamicIsland] /event error [\(code)]: \(message)")
                sendHTTP(
                    connection,
                    body: Self.errorBody(code: code, message: message),
                    statusCode: "400 Bad Request"
                )
            }
        } else {
            sendHTTP(connection, body: "{\"status\":\"ok\"}")
        }
    }

    /// Errors surfaced to POST /event callers so a bad payload no longer
    /// gets swallowed into a silent 200 OK.
    ///
    /// `code` is the stable machine-readable identifier; `message` is a
    /// human-friendly description that may vary by OS version / locale.
    private enum EventError: Error {
        case missingBody
        case invalidJSON(String)
        case invalidShape(String)

        var code: String {
            switch self {
            case .missingBody: return "missing_body"
            case .invalidJSON: return "invalid_json"
            case .invalidShape: return "invalid_shape"
            }
        }

        var message: String {
            switch self {
            case .missingBody: return "missing request body"
            case .invalidJSON(let reason): return "invalid JSON: \(reason)"
            case .invalidShape(let reason): return "invalid event shape: \(reason)"
            }
        }
    }

    /// Safely build a JSON error body. Runs fields through JSONSerialization
    /// so embedded quotes / newlines don't corrupt the response.
    private static func errorBody(code: String, message: String) -> String {
        let payload: [String: String] = [
            "status": "error",
            "code": code,
            "message": message,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"status\":\"error\",\"code\":\"\(code)\"}"
    }

    private func sendHTTP(_ connection: NWConnection, body: String, statusCode: String = "200 OK") {
        let response = "HTTP/1.1 \(statusCode)\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8)!, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Long-poll: waits up to 25s for user to tap Allow/Deny/Always, then returns the choice
    private func handleResponsePoll(_ connection: NWConnection) {
        let timeoutDecision = PermissionDecision(behavior: "timeout", rule: nil)
        responseLock.lock()
        if let response = pendingResponse {
            pendingResponse = nil
            responseLock.unlock()
            sendHTTP(connection, body: response.jsonBody)
            return
        }
        responseLock.unlock()

        // Long-poll: wait for response with timeout
        Task {
            let result = await withTaskGroup(of: PermissionDecision.self, returning: PermissionDecision.self) { group in
                group.addTask {
                    await withCheckedContinuation { continuation in
                        self.responseLock.lock()
                        // Check again in case it arrived
                        if let response = self.pendingResponse {
                            self.pendingResponse = nil
                            self.responseLock.unlock()
                            continuation.resume(returning: response)
                        } else {
                            self.responseWaiters.append(continuation)
                            self.responseLock.unlock()
                        }
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 25_000_000_000) // 25s timeout
                    return timeoutDecision
                }
                let first = await group.next()!
                group.cancelAll()
                return first
            }

            self.sendHTTP(connection, body: result.jsonBody)
        }
    }

    private func processEvent(_ data: Data) throws {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw EventError.invalidJSON(error.localizedDescription)
        }
        guard let json = parsed as? [String: Any] else {
            throw EventError.invalidShape("top-level value must be a JSON object")
        }

        let type = json["type"] as? String ?? "custom"

        // Handle thinking state
        if type == "thinking_start" {
            stateManager?.startThinking(source: json["source"] as? String)
            return
        } else if type == "thinking_stop" {
            stateManager?.stopThinking()
            return
        }

        // Subagent channel close — remove from session list, no island event
        if type == "subagent_stop" {
            if let agentId = json["agent_id"] as? String {
                stateManager?.removeSession(id: agentId)
            }
            return
        }

        // Regular events also stop thinking
        if type == "stop" {
            stateManager?.stopThinking()
        }

        let title = json["title"] as? String ?? type
        let subtitle = json["subtitle"] as? String ?? ""
        let detail = json["detail"] as? String
        let styleName = json["style"] as? String ?? "claude"
        let progress = json["progress"] as? Double
        let project = json["project"] as? String
        let source = json["source"] as? String

        // Progress semantics: in-progress events stay until complete,
        // completion (progress >= 1.0) gets a short celebratory duration
        let progressInFlight = progress.map { $0 < 1.0 } ?? false
        let progressComplete = progress.map { $0 >= 1.0 } ?? false

        let defaultDuration: Double = progressComplete ? 1.5 : 4.0
        let duration = json["duration"] as? Double ?? defaultDuration
        let persistent = json["persistent"] as? Bool
            ?? (styleName == "action" || styleName == "reminder" || progressInFlight)

        let style = EventStyle(rawValue: styleName) ?? .claude

        let icon: String
        if let customIcon = json["icon"] as? String {
            icon = customIcon
        } else {
            icon = Self.iconForType(type)
        }

        var suggestedRule: PermissionRuleSuggestion? = nil
        if let dict = json["suggested_rule"] as? [String: Any],
           let toolName = dict["toolName"] as? String,
           let ruleContent = dict["ruleContent"] as? String {
            suggestedRule = PermissionRuleSuggestion(toolName: toolName, ruleContent: ruleContent)
        }

        // #20 Phase 1: quick-reply button labels. Cap at 3 entries / 20
        // chars per label so the button row fits whichever expanded view
        // renders it (notch ~445 pt, capsule 420 pt). Non-string entries
        // are dropped silently.
        var quickReplies: [String]? = nil
        if let raw = json["quick_replies"] as? [Any] {
            let labels = raw
                .compactMap { $0 as? String }
                .map { String($0.prefix(20)) }
                .prefix(3)
            if !labels.isEmpty {
                quickReplies = Array(labels)
            }
        }

        let event = IslandEvent(
            icon: icon,
            title: title,
            subtitle: subtitle,
            style: style,
            duration: duration,
            detail: detail,
            progress: progress,
            persistent: persistent,
            project: project,
            source: source,
            suggestedRule: suggestedRule,
            quickReplies: quickReplies
        )

        // Route into the session tree: main session when no agent_id, else
        // keyed by agent_id so parallel subagents each get their own row.
        let agentId = json["agent_id"] as? String
        let agentType = json["agent_type"] as? String
        let sessionId = agentId ?? "main"
        stateManager?.updateSession(
            id: sessionId,
            agentType: agentType,
            project: project,
            title: title,
            subtitle: subtitle
        )

        stateManager?.pushEvent(event)
    }

    private static func iconForType(_ type: String) -> String {
        switch type {
        case "tool_start": return "🔧"
        case "tool_end": return "✅"
        case "notification": return "🔔"
        case "stop": return "🏁"
        case "error": return "❌"
        case "thinking": return "🧠"
        case "edit": return "✏️"
        case "bash": return "💻"
        case "search": return "🔍"
        case "read": return "📖"
        case "write": return "📝"
        default: return "🏝️"
        }
    }
}
