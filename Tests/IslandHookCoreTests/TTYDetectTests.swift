import XCTest
@testable import IslandHookCore

final class TTYDetectTests: XCTestCase {

    // MARK: - parsePSTTYOutput

    func testPSTTY_normalizesShortName() {
        XCTAssertEqual(parsePSTTYOutput("ttys003"), "/dev/ttys003")
    }

    func testPSTTY_passesAbsolutePathThrough() {
        XCTAssertEqual(parsePSTTYOutput("/dev/ttys003"), "/dev/ttys003")
    }

    func testPSTTY_trimsWhitespaceAndNewlines() {
        XCTAssertEqual(parsePSTTYOutput("  ttys003\n"), "/dev/ttys003")
        XCTAssertEqual(parsePSTTYOutput("\tttys003 "), "/dev/ttys003")
    }

    func testPSTTY_nilForQuestionMark() {
        // ps prints "?" or "??" when the process has no controlling tty
        // (daemons, GUI launches). We don't want to forward bogus device
        // names to the click handler.
        XCTAssertNil(parsePSTTYOutput("?"))
        XCTAssertNil(parsePSTTYOutput("??"))
        XCTAssertNil(parsePSTTYOutput(" ? "))
    }

    func testPSTTY_nilForEmpty() {
        XCTAssertNil(parsePSTTYOutput(""))
        XCTAssertNil(parsePSTTYOutput("   "))
        XCTAssertNil(parsePSTTYOutput("\n\n"))
    }

    func testPSTTY_handlesPtsStyle() {
        // Linux-flavoured tty paths still parse; the AppleScript side
        // simply won't match them on macOS.
        XCTAssertEqual(parsePSTTYOutput("pts/3"), "/dev/pts/3")
    }

    // MARK: - HookPlan integration

    func testDecorate_emitsTTYWhenSet() {
        guard let plan = parseHookPlan(
            payload: [
                "hook_event_name": "PreToolUse", "tool_name": "Bash",
                "tool_input": ["command": "ls"],
                "cwd": "/tmp/demo",
            ],
            tty: "/dev/ttys003"
        ) else {
            XCTFail("payload should parse")
            return
        }
        let body = plan.decorate(["title": "x"])
        XCTAssertEqual(body["tty"] as? String, "/dev/ttys003")
    }

    func testDecorate_omitsTTYWhenNil() {
        guard let plan = parseHookPlan(
            payload: [
                "hook_event_name": "PreToolUse", "tool_name": "Bash",
                "tool_input": ["command": "ls"],
                "cwd": "/tmp/demo",
            ]
        ) else {
            XCTFail("payload should parse")
            return
        }
        let body = plan.decorate(["title": "x"])
        XCTAssertNil(body["tty"])
    }

    func testDecorate_omitsTTYWhenEmptyString() {
        guard let plan = parseHookPlan(
            payload: [
                "hook_event_name": "PreToolUse", "tool_name": "Bash",
                "tool_input": ["command": "ls"],
                "cwd": "/tmp/demo",
            ],
            tty: ""
        ) else {
            XCTFail("payload should parse")
            return
        }
        let body = plan.decorate(["title": "x"])
        XCTAssertNil(body["tty"])
    }
}
