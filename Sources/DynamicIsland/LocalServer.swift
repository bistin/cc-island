import Foundation
import Network

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
class LocalServer {
    let port: UInt16
    private var listener: NWListener?
    private weak var stateManager: IslandStateManager?

    /// Pending permission response — hook script polls this
    private var pendingResponse: String?
    private let responseLock = NSLock()
    private var responseWaiters: [CheckedContinuation<String, Never>] = []

    init(stateManager: IslandStateManager, port: UInt16 = 9423) {
        self.stateManager = stateManager
        self.port = port
    }

    /// Called from UI when user taps Allow/Deny
    func setResponse(_ value: String) {
        responseLock.lock()
        let waiters = responseWaiters
        responseWaiters.removeAll()
        if waiters.isEmpty {
            pendingResponse = value
        }
        responseLock.unlock()
        for waiter in waiters {
            waiter.resume(returning: value)
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

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            let raw = String(data: data, encoding: .utf8) ?? ""
            let firstLine = raw.components(separatedBy: "\r\n").first ?? ""

            if firstLine.contains("/response") {
                // GET /response — hook script polls for user's permission choice
                self.handleResponsePoll(connection)
            } else if firstLine.contains("/event") {
                // POST /event — normal event
                self.sendHTTP(connection, body: "{\"status\":\"ok\"}")
                if let bodyRange = raw.range(of: "\r\n\r\n") {
                    let bodyString = String(raw[bodyRange.upperBound...])
                    if let bodyData = bodyString.data(using: .utf8) {
                        self.processEvent(bodyData)
                    }
                }
            } else {
                self.sendHTTP(connection, body: "{\"status\":\"ok\"}")
            }
        }
    }

    private func sendHTTP(_ connection: NWConnection, body: String, statusCode: String = "200 OK") {
        let response = "HTTP/1.1 \(statusCode)\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8)!, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Long-poll: waits up to 25s for user to tap Allow/Deny, then returns the choice
    private func handleResponsePoll(_ connection: NWConnection) {
        responseLock.lock()
        if let response = pendingResponse {
            pendingResponse = nil
            responseLock.unlock()
            sendHTTP(connection, body: "{\"decision\":\"\(response)\"}")
            return
        }
        responseLock.unlock()

        // Long-poll: wait for response with timeout
        Task {
            let result = await withTaskGroup(of: String.self, returning: String.self) { group in
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
                    return "timeout"
                }
                let first = await group.next()!
                group.cancelAll()
                return first
            }

            if result == "timeout" {
                self.sendHTTP(connection, body: "{\"decision\":\"timeout\"}")
            } else {
                self.sendHTTP(connection, body: "{\"decision\":\"\(result)\"}")
            }
        }
    }

    private func processEvent(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[DynamicIsland] Invalid JSON")
            return
        }

        let type = json["type"] as? String ?? "custom"

        // Handle thinking state
        if type == "thinking_start" {
            stateManager?.startThinking()
            return
        } else if type == "thinking_stop" {
            stateManager?.stopThinking()
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

        let event = IslandEvent(
            icon: icon,
            title: title,
            subtitle: subtitle,
            style: style,
            duration: duration,
            detail: detail,
            progress: progress,
            persistent: persistent,
            project: project
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
