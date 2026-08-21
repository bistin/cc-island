import XCTest
@testable import IslandHookCore

final class TmuxSocketTests: XCTestCase {

    /// Captured from a live server rather than invented:
    /// `<socket-path>,<server-pid>,<session-index>`.
    func testTheSocketIsTheFirstFieldOfTMUX() {
        XCTAssertEqual(tmuxSocketPath(fromTMUXEnv: "/private/tmp/tmux-501/probe-sock,36880,0"),
                       "/private/tmp/tmux-501/probe-sock")
        XCTAssertEqual(tmuxSocketPath(fromTMUXEnv: "/private/tmp/tmux-501/default,123,0"),
                       "/private/tmp/tmux-501/default")
    }

    /// Outside tmux there is no variable at all, which is the ordinary case and not a failure.
    func testOutsideTmuxThereIsNothing() {
        XCTAssertNil(tmuxSocketPath(fromTMUXEnv: nil))
        XCTAssertNil(tmuxSocketPath(fromTMUXEnv: ""))
    }

    /// The value reaches the app in an HTTP payload. It goes to `Process` as argv rather than
    /// through a shell, so this is a shape check rather than a quoting one — but "looks like a
    /// socket path" is cheaper to require than to reason about later.
    func testAnythingThatIsNotAnAbsolutePathIsRefused() {
        for bad in ["relative/path,1,0", "not-a-path", ",1,0", "  ,1,0", "-S,1,0"] {
            XCTAssertNil(tmuxSocketPath(fromTMUXEnv: bad), bad)
        }
    }

    func testNullBytesAndAbsurdLengthsAreRefused() {
        XCTAssertNil(tmuxSocketPath(fromTMUXEnv: "/tmp/a\u{0}b,1,0"))
        XCTAssertNil(tmuxSocketPath(fromTMUXEnv: "/" + String(repeating: "x", count: 2000) + ",1,0"))
    }

    /// A socket path may contain anything a path may contain, commas included — but tmux writes
    /// its own value, and splitting on the first comma is what matches the format it writes.
    func testOnlyTheFirstCommaSplits() {
        XCTAssertEqual(tmuxSocketPath(fromTMUXEnv: "/tmp/sock,1,0"), "/tmp/sock")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(tmuxSocketPath(fromTMUXEnv: " /tmp/sock ,1,0"), "/tmp/sock")
    }

    /// The hook forwards it into the payload, and the app reads the same field back.
    func testThePlanCarriesItIntoThePayload() throws {
        let plan = try XCTUnwrap(parseHookPlan(
            payload: ["hook_event_name": "PreToolUse", "tool_name": "Bash",
                      "cwd": "/Users/x/app/thing"],
            tmuxSocket: "/private/tmp/tmux-501/work"
        ))
        let payload = plan.decorate(["title": "Terminal"])
        XCTAssertEqual(payload["tmux_socket"] as? String, "/private/tmp/tmux-501/work")
    }

    func testNoSocketMeansNoFieldRatherThanAnEmptyOne() throws {
        let plan = try XCTUnwrap(parseHookPlan(
            payload: ["hook_event_name": "PreToolUse", "tool_name": "Bash",
                      "cwd": "/Users/x/app/thing"]
        ))
        XCTAssertNil(plan.decorate(["title": "Terminal"])["tmux_socket"])
    }
}
