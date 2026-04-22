import XCTest
@testable import IslandHookCore

final class HookPlanTests: XCTestCase {

    // MARK: - Source detection

    func testClaudeCode_PascalCaseEvent() {
        let plan = parseHookPlan(payload: [
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "cwd": "/Users/bistin/projects/demo",
        ])
        XCTAssertEqual(plan?.source, "claude")
        XCTAssertEqual(plan?.event, "PreToolUse")
        XCTAssertEqual(plan?.tool, "Bash")
        XCTAssertEqual(plan?.project, "demo")
    }

    func testCopilotCLI_camelCaseEventNormalizedToPascalCase() {
        let plan = parseHookPlan(payload: [
            "hook_event_name": "preToolUse",
            "tool_name": "bash",
            "cwd": "/tmp/cp-demo",
        ])
        XCTAssertEqual(plan?.source, "copilot")
        XCTAssertEqual(plan?.event, "PreToolUse") // normalized
        XCTAssertEqual(plan?.tool, "Bash")        // normalized
    }

    func testCopilotLegacy_toolNameAtRoot() {
        let plan = parseHookPlan(payload: [
            "toolName": "edit",
            "toolArgs": #"{"file_path":"/tmp/a.txt"}"#,
            "cwd": "/tmp/old-copilot",
        ])
        XCTAssertEqual(plan?.source, "copilot")
        XCTAssertEqual(plan?.event, "PreToolUse")
        XCTAssertEqual(plan?.tool, "Edit")
    }

    func testCopilotLegacy_postToolUseWhenResultTypePresent() {
        let plan = parseHookPlan(payload: [
            "toolName": "bash",
            "toolResult": ["resultType": "ok"],
            "cwd": "/tmp/x",
        ])
        XCTAssertEqual(plan?.event, "PostToolUse")
    }

    func testCodex_envOverrideWins() {
        let plan = parseHookPlan(
            payload: ["hook_event_name": "PreToolUse", "cwd": "/tmp/x"],
            env: ["ISLAND_SOURCE": "codex"]
        )
        XCTAssertEqual(plan?.source, "codex")
    }

    func testUnroutablePayload_returnsNil() {
        // No hook_event_name, no toolName, no other recognizable field.
        XCTAssertNil(parseHookPlan(payload: ["cwd": "/tmp"]))
    }

    // MARK: - Event normalization covers all Copilot events

    func testCopilotEventMap() {
        let pairs: [(String, String)] = [
            ("preToolUse", "PreToolUse"),
            ("postToolUse", "PostToolUse"),
            ("userPromptSubmitted", "UserPromptSubmit"),
            ("sessionStart", "SessionStart"),
            ("sessionEnd", "SessionEnd"),
            ("errorOccurred", "Error"),
        ]
        for (input, expected) in pairs {
            let plan = parseHookPlan(payload: [
                "hook_event_name": input, "cwd": "/tmp/x",
            ])
            XCTAssertEqual(plan?.event, expected, "Expected \(input) → \(expected)")
        }
    }

    // MARK: - Project & subagent labels

    func testProjectFromCwd() {
        let plan = parseHookPlan(payload: [
            "hook_event_name": "PreToolUse",
            "cwd": "/Users/someone/Projects/my-repo",
        ])
        XCTAssertEqual(plan?.project, "my-repo")
        XCTAssertEqual(plan?.displayProject, "my-repo")
    }

    func testSubagentOverrides_displayProject() {
        let plan = parseHookPlan(payload: [
            "hook_event_name": "PreToolUse",
            "cwd": "/Users/someone/Projects/parent",
            "agent_id": "abc-123",
            "agent_type": "Explore",
        ])
        XCTAssertEqual(plan?.project, "parent")
        XCTAssertEqual(plan?.displayProject, "↳ Explore")
        XCTAssertEqual(plan?.agentId, "abc-123")
        XCTAssertEqual(plan?.agentType, "Explore")
    }

    func testEmptyCwd_projectEmpty() {
        let plan = parseHookPlan(payload: ["hook_event_name": "SessionStart"])
        XCTAssertEqual(plan?.project, "")
        XCTAssertEqual(plan?.displayProject, "")
    }

    // MARK: - Tool input extraction

    func testFilePath_fromClaudeToolInput() {
        let plan = parseHookPlan(payload: [
            "hook_event_name": "PreToolUse",
            "tool_name": "Edit",
            "tool_input": ["file_path": "/tmp/a.swift"],
            "cwd": "/tmp/x",
        ])
        XCTAssertEqual(plan?.filePath, "/tmp/a.swift")
    }

    func testFilePath_fromCopilotToolArgs() {
        let plan = parseHookPlan(payload: [
            "toolName": "edit",
            "toolArgs": #"{"file_path":"/tmp/b.txt"}"#,
            "cwd": "/tmp",
        ])
        XCTAssertEqual(plan?.filePath, "/tmp/b.txt")
    }

    func testCommand_fromClaudeToolInput() {
        let plan = parseHookPlan(payload: [
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": "git status"],
            "cwd": "/tmp",
        ])
        XCTAssertEqual(plan?.command, "git status")
    }

    // MARK: - Decoration

    func testDecorate_addsSourceProjectAgent() {
        let plan = parseHookPlan(payload: [
            "hook_event_name": "PreToolUse",
            "cwd": "/tmp/foo",
            "agent_id": "xyz",
            "agent_type": "Plan",
        ])!
        let decorated = plan.decorate(["title": "hi"])
        XCTAssertEqual(decorated["title"] as? String, "hi")
        XCTAssertEqual(decorated["source"] as? String, "claude")
        XCTAssertEqual(decorated["project"] as? String, "↳ Plan")
        XCTAssertEqual(decorated["agent_id"] as? String, "xyz")
        XCTAssertEqual(decorated["agent_type"] as? String, "Plan")
    }

    // MARK: - shouldCachePreToolUse

    func testShouldCachePreToolUse() {
        let cacheable = ["Edit", "Write", "Bash", "MultiEdit", "NotebookEdit"]
        let notCacheable = ["Read", "Grep", "Glob", "Agent"]
        for tool in cacheable {
            let plan = parseHookPlan(payload: [
                "hook_event_name": "PreToolUse", "tool_name": tool, "cwd": "/tmp",
            ])
            XCTAssertTrue(plan?.shouldCachePreToolUse ?? false, "\(tool) should cache")
        }
        for tool in notCacheable {
            let plan = parseHookPlan(payload: [
                "hook_event_name": "PreToolUse", "tool_name": tool, "cwd": "/tmp",
            ])
            XCTAssertFalse(plan?.shouldCachePreToolUse ?? true, "\(tool) should not cache")
        }
    }
}
