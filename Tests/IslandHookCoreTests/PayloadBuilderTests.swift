import XCTest
@testable import IslandHookCore

final class PayloadBuilderTests: XCTestCase {

    // Helper: build a HookPlan quickly for assertions.
    private func plan(_ raw: [String: Any], env: [String: String] = [:]) -> HookPlan {
        guard let p = parseHookPlan(payload: raw, env: env) else {
            fatalError("Unparseable payload in test")
        }
        return p
    }

    // MARK: - PreToolUse

    func testPreToolUse_Edit_emitsDiffPreview() {
        let p = plan([
            "hook_event_name": "PreToolUse", "tool_name": "Edit",
            "tool_input": [
                "file_path": "/tmp/x.swift",
                "old_string": "let x = 1", "new_string": "let x = 42",
            ],
            "cwd": "/tmp/demo",
        ])
        let body = buildPreToolUsePayload(p)
        XCTAssertEqual(body["title"] as? String, "Editing")
        XCTAssertEqual(body["subtitle"] as? String, "x.swift")
        XCTAssertEqual(body["style"] as? String, "claude")
        XCTAssertEqual(body["detail"] as? String, "- let x = 1\n+ let x = 42")
        XCTAssertEqual(body["source"] as? String, "claude")
    }

    func testPreToolUse_Edit_multiEditFallback() {
        let p = plan([
            "hook_event_name": "PreToolUse", "tool_name": "Edit",
            "tool_input": [
                "file_path": "/tmp/x.swift",
                "edits": [
                    ["old_string": "a", "new_string": "b"] as [String: Any],
                    ["old_string": "c", "new_string": "d"] as [String: Any],
                ],
            ] as [String: Any],
            "cwd": "/tmp/demo",
        ])
        let body = buildPreToolUsePayload(p)
        XCTAssertEqual(body["detail"] as? String, "- a\n+ b")
    }

    func testPreToolUse_Edit_emptyFilePath_fallsBackTo_file() {
        let p = plan([
            "hook_event_name": "PreToolUse", "tool_name": "Edit",
            "tool_input": ["old_string": "x", "new_string": "y"],
            "cwd": "/tmp/demo",
        ])
        XCTAssertEqual(buildPreToolUsePayload(p)["subtitle"] as? String, "file")
    }

    func testPreToolUse_Write_hasContentPreview() {
        let p = plan([
            "hook_event_name": "PreToolUse", "tool_name": "Write",
            "tool_input": [
                "file_path": "/tmp/w.txt",
                "content": "hello\nworld",
            ],
            "cwd": "/tmp/demo",
        ])
        let body = buildPreToolUsePayload(p)
        XCTAssertEqual(body["title"] as? String, "Writing")
        XCTAssertEqual(body["detail"] as? String, "+ hello\n+ world")
    }

    func testPreToolUse_Read_noDetail() {
        let p = plan([
            "hook_event_name": "PreToolUse", "tool_name": "Read",
            "tool_input": ["file_path": "/tmp/r.txt"],
            "cwd": "/tmp/demo",
        ])
        let body = buildPreToolUsePayload(p)
        XCTAssertEqual(body["title"] as? String, "Reading")
        XCTAssertEqual(body["subtitle"] as? String, "r.txt")
        XCTAssertNil(body["detail"])
    }

    func testPreToolUse_Bash_usesDescription() {
        let p = plan([
            "hook_event_name": "PreToolUse", "tool_name": "Bash",
            "tool_input": ["command": "git status", "description": "Show status"],
            "cwd": "/tmp/demo",
        ])
        let body = buildPreToolUsePayload(p)
        XCTAssertEqual(body["title"] as? String, "Terminal")
        XCTAssertEqual(body["subtitle"] as? String, "Show status")
    }

    func testPreToolUse_Bash_fallsBackToCommandIfNoDescription() {
        let p = plan([
            "hook_event_name": "PreToolUse", "tool_name": "Bash",
            "tool_input": ["command": "ls -la"],
            "cwd": "/tmp/demo",
        ])
        XCTAssertEqual(buildPreToolUsePayload(p)["subtitle"] as? String, "ls -la")
    }

    func testPreToolUse_Grep_showsPattern() {
        let p = plan([
            "hook_event_name": "PreToolUse", "tool_name": "Grep",
            "tool_input": ["pattern": "TODO"],
            "cwd": "/tmp/demo",
        ])
        let body = buildPreToolUsePayload(p)
        XCTAssertEqual(body["title"] as? String, "Searching")
        XCTAssertEqual(body["subtitle"] as? String, "TODO")
    }

    func testPreToolUse_Agent_fallsBackToAgentTypeIfNoDescription() {
        let p = plan([
            "hook_event_name": "PreToolUse", "tool_name": "Agent",
            "tool_input": ["subagent_type": "Explore"],
            "cwd": "/tmp/demo",
        ])
        XCTAssertEqual(buildPreToolUsePayload(p)["subtitle"] as? String, "Explore")
    }

    func testPreToolUse_MCP_toolStripsPrefix() {
        let p = plan([
            "hook_event_name": "PreToolUse", "tool_name": "mcp__notion__search",
            "cwd": "/tmp/demo",
        ])
        XCTAssertEqual(buildPreToolUsePayload(p)["title"] as? String, "search")
    }

    // MARK: - PostToolUse

    func testPostToolUse_EditEmitsSaved() {
        let p = plan([
            "hook_event_name": "PostToolUse", "tool_name": "Edit",
            "tool_input": ["file_path": "/tmp/x.swift"],
            "cwd": "/tmp/demo",
        ])
        let body = buildPostToolUsePayload(p)
        XCTAssertEqual(body?["title"] as? String, "Saved")
        XCTAssertEqual(body?["subtitle"] as? String, "x.swift")
        XCTAssertEqual(body?["style"] as? String, "success")
    }

    func testPostToolUse_ReadReturnsNil() {
        let p = plan([
            "hook_event_name": "PostToolUse", "tool_name": "Read",
            "tool_input": ["file_path": "/tmp/x"],
            "cwd": "/tmp",
        ])
        XCTAssertNil(buildPostToolUsePayload(p))
    }

    // MARK: - Failure events

    func testPostToolUseFailure_usesToolErrorField() {
        let p = plan([
            "hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
            "tool_error": "exit code 1", "cwd": "/tmp",
        ])
        let body = buildPostToolUseFailurePayload(p)
        XCTAssertEqual(body["title"] as? String, "Tool failed")
        XCTAssertEqual(body["subtitle"] as? String, "exit code 1")
        XCTAssertEqual(body["style"] as? String, "error")
    }

    func testPermissionDenied_withReason() {
        let p = plan([
            "hook_event_name": "PermissionDenied", "tool_name": "Edit",
            "denial_reason": "File outside allowed paths", "cwd": "/tmp",
        ])
        let body = buildPermissionDeniedPayload(p)
        XCTAssertEqual(body["title"] as? String, "Denied")
        XCTAssertEqual(body["subtitle"] as? String, "File outside allowed paths")
    }

    func testStopFailure_apiError() {
        let p = plan([
            "hook_event_name": "StopFailure", "stop_error": "rate limit", "cwd": "/tmp",
        ])
        let body = buildStopFailurePayload(p)
        XCTAssertEqual(body["title"] as? String, "Error")
        XCTAssertEqual(body["subtitle"] as? String, "rate limit")
    }

    func testStopFailure_fallbackWhenErrorMissing() {
        let p = plan(["hook_event_name": "StopFailure", "cwd": "/tmp"])
        XCTAssertEqual(buildStopFailurePayload(p)["subtitle"] as? String, "API error")
    }

    // MARK: - Notification

    func testNotification_permissionPromptSkipped() {
        let p = plan([
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "message": "Allow this?",
            "cwd": "/tmp",
        ])
        XCTAssertNil(buildNotificationPayload(p))
    }

    func testNotification_regularMessageEmits() {
        let p = plan([
            "hook_event_name": "Notification",
            "message": "Something happened",
            "cwd": "/tmp",
        ])
        let body = buildNotificationPayload(p)
        XCTAssertEqual(body?["title"] as? String, "Claude Code")
        XCTAssertEqual(body?["subtitle"] as? String, "Something happened")
        XCTAssertEqual(body?["style"] as? String, "reminder")
    }

    // MARK: - Stop (asking-question detection)

    func testStop_questionMark_emitsWaitingWithQuestion() {
        let p = plan([
            "hook_event_name": "Stop",
            "last_assistant_message": "Would you like me to continue?",
            "cwd": "/tmp",
        ])
        let body = buildStopPayload(p)
        XCTAssertEqual(body["title"] as? String, "Waiting")
        XCTAssertEqual(body["subtitle"] as? String, "Would you like me to continue?")
        XCTAssertEqual(body["style"] as? String, "reminder")
        XCTAssertEqual(body["detail"] as? String, "Would you like me to continue?")
    }

    func testStop_multilineMessage_subtitleIsLastLine() {
        let msg = "I've made the changes to foo.swift.\n\nShould I run the tests?"
        let p = plan([
            "hook_event_name": "Stop",
            "last_assistant_message": msg,
            "cwd": "/tmp",
        ])
        let body = buildStopPayload(p)
        XCTAssertEqual(body["subtitle"] as? String, "Should I run the tests?")
        XCTAssertEqual(body["detail"] as? String, msg)
    }

    func testStop_listFollowedByQuestion_takesLastLine() {
        let msg = "Done with all 5 changes:\n- a\n- b\n- c\nWant me to commit?"
        let p = plan([
            "hook_event_name": "Stop",
            "last_assistant_message": msg,
            "cwd": "/tmp",
        ])
        XCTAssertEqual(buildStopPayload(p)["subtitle"] as? String, "Want me to commit?")
    }

    func testStop_longQuestion_truncatedTo50() {
        // A single sentence with no internal punctuation — exercises the
        // 50-char clip after sentence extraction.
        let msg = String(repeating: "very ", count: 30)
            + "long question with no internal punctuation?"
        let p = plan([
            "hook_event_name": "Stop",
            "last_assistant_message": msg,
            "cwd": "/tmp",
        ])
        let sub = buildStopPayload(p)["subtitle"] as? String ?? ""
        XCTAssertLessThanOrEqual(sub.count, 51)
        XCTAssertTrue(sub.hasSuffix("…"))
    }

    func testExtractLastQuestion_singleLine() {
        XCTAssertEqual(extractLastQuestion(from: "Hello?"), "Hello?")
    }

    func testExtractLastQuestion_multilineLastNonEmpty() {
        XCTAssertEqual(
            extractLastQuestion(from: "First\n\nLast?"),
            "Last?"
        )
    }

    func testExtractLastQuestion_trailingWhitespace() {
        XCTAssertEqual(
            extractLastQuestion(from: "Question?  \n\n  "),
            "Question?"
        )
    }

    func testExtractLastQuestion_empty() {
        XCTAssertEqual(extractLastQuestion(from: ""), "")
    }

    func testExtractLastQuestion_chinesePeriodAsSeparator() {
        XCTAssertEqual(
            extractLastQuestion(from: "送出去了。看起來怎樣？"),
            "看起來怎樣？"
        )
    }

    func testExtractLastQuestion_englishPeriodSeparator() {
        XCTAssertEqual(
            extractLastQuestion(from: "First sentence. Second one?"),
            "Second one?"
        )
    }

    func testExtractLastQuestion_mixedPunctuation_takesAfterLastTerminator() {
        XCTAssertEqual(
            extractLastQuestion(from: "Made the change! Want to commit?"),
            "Want to commit?"
        )
    }

    func testStop_declarativeMessage_emitsDone() {
        let p = plan([
            "hook_event_name": "Stop",
            "last_assistant_message": "All done.",
            "cwd": "/tmp",
        ])
        let body = buildStopPayload(p)
        XCTAssertEqual(body["title"] as? String, "Done")
        XCTAssertEqual(body["style"] as? String, "success")
    }

    func testStop_fullwidthQuestionMark() {
        let p = plan([
            "hook_event_name": "Stop",
            "last_assistant_message": "要繼續嗎？",
            "cwd": "/tmp",
        ])
        XCTAssertEqual(buildStopPayload(p)["title"] as? String, "Waiting")
    }

    // MARK: - PermissionRequest with FIFO cache

    func testPermissionRequest_EnrichesWithCachedDiff() {
        let p = plan([
            "hook_event_name": "PermissionRequest", "tool_name": "Edit",
            "tool_input": ["file_path": "/tmp/x.swift"],
            "cwd": "/tmp",
        ])
        let cached: [String: Any] = [
            "old_string": "let x = 1",
            "new_string": "let x = 42",
        ]
        let body = buildPermissionRequestPayload(p, cachedInput: cached, cachedToolName: "Edit")
        XCTAssertEqual(body["title"] as? String, "Permission")
        XCTAssertEqual(body["detail"] as? String, "- let x = 1\n+ let x = 42")
        XCTAssertEqual(body["style"] as? String, "action")
    }

    func testPermissionRequest_NoCachedInput_stillBuildsWithoutDetail() {
        let p = plan([
            "hook_event_name": "PermissionRequest", "tool_name": "Edit",
            "tool_input": ["file_path": "/tmp/x.swift"],
            "cwd": "/tmp",
        ])
        let body = buildPermissionRequestPayload(p, cachedInput: nil, cachedToolName: nil)
        XCTAssertEqual(body["title"] as? String, "Permission")
        XCTAssertNil(body["detail"])
    }

    func testPermissionRequest_CachedToolMismatch_ignored() {
        let p = plan([
            "hook_event_name": "PermissionRequest", "tool_name": "Edit",
            "tool_input": ["file_path": "/tmp/x"],
            "cwd": "/tmp",
        ])
        // cached name differs from current tool → do not enrich
        let body = buildPermissionRequestPayload(
            p,
            cachedInput: ["old_string": "a", "new_string": "b"],
            cachedToolName: "Bash"
        )
        XCTAssertNil(body["detail"])
    }

    // MARK: - Session lifecycle

    func testSessionStart_usesSourceField() {
        let p = plan([
            "hook_event_name": "SessionStart", "source": "resume", "cwd": "/tmp",
        ])
        let body = buildSessionStartPayload(p)
        XCTAssertEqual(body["title"] as? String, "Session")
        XCTAssertEqual(body["subtitle"] as? String, "resume")
    }

    func testPreCompactAndPostCompact() {
        let p = plan(["hook_event_name": "PreCompact", "cwd": "/tmp"])
        XCTAssertEqual(buildPreCompactPayload(p)["title"] as? String, "Compacting")
        XCTAssertEqual(buildPostCompactPayload(p)["title"] as? String, "Compacted")
    }
}
