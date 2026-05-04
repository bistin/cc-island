import Foundation

/// Self-test actions surfaced from Settings → Diagnostics & Tools.
///
/// Each action fires through the same code path a real hook would,
/// so a green checkmark verifies the chain end-to-end (URLSession →
/// LocalServer.handleConnection → JSON parse → IslandStateManager →
/// SwiftUI render). Any failure points at the layer that broke
/// rather than relying on a real Claude session to surface it.
enum SelfTest {
    enum Outcome: Equatable {
        case success(String)
        case failure(String)
    }

    /// `POST /event` with a plain `info` event. Auto-dismisses after
    /// 3 s. Verifies the basic event path.
    static func sendTestEvent() async -> Outcome {
        let body: [String: Any] = [
            "title": "Self-test",
            "subtitle": "It works.",
            "style": "info",
            "duration": 3,
            "source": "claude",
            "project": "self-test",
        ]
        return await postEvent(body, action: "test event")
    }

    /// `POST /event` with an `action` style event so the user can
    /// see Allow / Deny buttons render. They click one to dismiss;
    /// either click verifies the decision pipeline.
    static func sendTestPermissionFlow() async -> Outcome {
        let body: [String: Any] = [
            "title": "Permission",
            "subtitle": "Bash · echo hello",
            "style": "action",
            "persistent": true,
            "detail": "echo \"hello from self-test\"",
            "source": "claude",
            "project": "self-test",
        ]
        return await postEvent(body, action: "permission test")
    }

    /// Pipe a synthetic `PreToolUse` payload into the deployed Codex
    /// hook binary if one is installed. Verifies the Codex
    /// installation works end-to-end (binary present, JSON parse,
    /// HTTP back to the local server).
    static func testCodexHook(deployedHookURL: URL) async -> Outcome {
        guard FileManager.default.fileExists(atPath: deployedHookURL.path) else {
            return .failure("Codex hook not installed at \(deployedHookURL.path)")
        }
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": "echo codex self-test"],
            "cwd": NSHomeDirectory(),
            "session_id": "self-test-\(UUID().uuidString)",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failure("could not serialise test payload")
        }

        return await Task.detached { () -> Outcome in
            let process = Process()
            process.executableURL = deployedHookURL
            process.environment = [
                "ISLAND_SOURCE": "codex",
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ]
            let stdinPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = Pipe()
            process.standardError = stderrPipe
            do {
                try process.run()
                stdinPipe.fileHandleForWriting.write(data)
                try? stdinPipe.fileHandleForWriting.close()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return .success("Codex hook ran cleanly. Look for the test event on the island.")
                }
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? ""
                return .failure("hook exited \(process.terminationStatus): \(errText.isEmpty ? "(no stderr)" : errText)")
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }

    // MARK: - HTTP helper

    private static func postEvent(_ body: [String: Any], action: String) async -> Outcome {
        guard let url = URL(string: "http://127.0.0.1:9423/event") else {
            return .failure("could not build test URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failure("could not serialise \(action): \(error.localizedDescription)")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure("\(action): no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                return .failure("\(action): HTTP \(http.statusCode) \(text)")
            }
            return .success("Sent \(action). Look for it on the island.")
        } catch {
            return .failure("\(action): \(error.localizedDescription)")
        }
    }
}
