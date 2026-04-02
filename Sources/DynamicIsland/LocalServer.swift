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

    init(stateManager: IslandStateManager, port: UInt16 = 9423) {
        self.stateManager = stateManager
        self.port = port
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
            defer { connection.cancel() }

            if let error {
                print("[DynamicIsland] Connection error: \(error)")
                return
            }

            guard let data else { return }

            // Parse the HTTP request to extract the JSON body
            let raw = String(data: data, encoding: .utf8) ?? ""

            // Send HTTP response
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}"
            let responseData = response.data(using: .utf8)!
            connection.send(content: responseData, completion: .contentProcessed { _ in })

            // Handle CORS preflight
            if raw.hasPrefix("OPTIONS") { return }

            // Extract JSON body (after the blank line in HTTP request)
            guard let bodyRange = raw.range(of: "\r\n\r\n") else { return }
            let bodyString = String(raw[bodyRange.upperBound...])

            guard let bodyData = bodyString.data(using: .utf8) else { return }
            self?.processEvent(bodyData)
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
        let duration = json["duration"] as? Double ?? 4.0
        let progress = json["progress"] as? Double

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
            progress: progress
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
