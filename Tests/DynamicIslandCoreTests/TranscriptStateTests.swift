import XCTest
@testable import DynamicIslandCore

final class TranscriptStateTests: XCTestCase {

    // A fixed clock, so staleness is arithmetic rather than a race with the test runner.
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func at(_ offset: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: now.addingTimeInterval(offset))
    }

    private func read(_ lines: [String], staleAfter: TimeInterval = TranscriptState.defaultStaleAfter) -> TranscriptReading {
        TranscriptState.read(lines: lines, now: now, staleAfter: staleAfter)
    }

    // Shapes taken from a real transcript rather than invented, so a change in what Claude Code
    // writes shows up here as a failing test instead of as a wrong island.
    private func turnDuration(_ ts: String) -> String {
        #"{"type":"system","subtype":"turn_duration","durationMs":74731,"timestamp":"\#(ts)"}"#
    }
    private func endTurn(_ ts: String) -> String {
        #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text"}]},"timestamp":"\#(ts)"}"#
    }
    private func toolUse(_ ts: String) -> String {
        #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash"}]},"timestamp":"\#(ts)"}"#
    }
    private func toolResult(_ ts: String) -> String {
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]},"timestamp":"\#(ts)"}"#
    }
    private func prompt(_ ts: String) -> String {
        #"{"type":"user","message":{"content":"do the thing"},"timestamp":"\#(ts)"}"#
    }
    private func interrupted(_ ts: String) -> String {
        #"{"type":"user","interruptedMessageId":"m1","message":{"content":"[Request interrupted]"},"timestamp":"\#(ts)"}"#
    }

    // MARK: - Nothing to read

    func testEmptyFileIsUnknown() {
        XCTAssertEqual(read([]).activity, .unknown)
    }

    func testBlankLinesAreUnknown() {
        XCTAssertEqual(read(["", "   ", "\n"]).activity, .unknown)
    }

    func testUnparseableLinesAreUnknownNotACrash() {
        XCTAssertEqual(read(["not json", "{ broken", "]["]).activity, .unknown)
    }

    /// Housekeeping is roughly a third of the file. A reader that took the last line would be
    /// reading a file-history snapshot much of the time, so on its own it decides nothing.
    func testBookkeepingOnlyIsUnknown() {
        let lines = [
            #"{"type":"mode","mode":"default"}"#,
            #"{"type":"ai-title","aiTitle":"something"}"#,
            #"{"type":"file-history-snapshot","messageId":"m1"}"#,
        ]
        XCTAssertEqual(read(lines).activity, .unknown)
    }

    // MARK: - Idle

    func testTurnDurationMeansIdle() {
        let r = read([prompt(at(-60)), toolUse(at(-50)), toolResult(at(-40)), endTurn(at(-30)), turnDuration(at(-30))])
        XCTAssertEqual(r.activity, .idle)
        XCTAssertEqual(r.decidedBy, "system")
    }

    /// `end_turn` and `turn_duration` are written separately. A file caught between them must not
    /// report the finished turn as still running.
    func testEndTurnAloneIsIdle() {
        let r = read([toolResult(at(-40)), endTurn(at(-30))])
        XCTAssertEqual(r.activity, .idle)
        XCTAssertEqual(r.decidedBy, "assistant")
    }

    /// Claude Code writes no `turn_duration` for an interrupted turn, so without this the session
    /// reads as working until it goes stale.
    func testInterruptedTurnIsIdle() {
        XCTAssertEqual(read([toolUse(at(-40)), interrupted(at(-30))]).activity, .idle)
    }

    func testBookkeepingAfterATurnEndDoesNotReopenIt() {
        let lines = [
            endTurn(at(-40)), turnDuration(at(-40)),
            #"{"type":"file-history-snapshot","messageId":"m2"}"#,
            #"{"type":"pr-link","prNumber":61,"timestamp":"\#(at(-20))"}"#,
        ]
        XCTAssertEqual(read(lines).activity, .idle)
    }

    // MARK: - Working

    func testOutstandingToolUseIsWorking() {
        let r = read([prompt(at(-30)), toolUse(at(-20))])
        XCTAssertEqual(r.activity, .working)
        XCTAssertEqual(r.decidedBy, "assistant")
    }

    func testToolResultIsWorkingBecauseClaudeHasTheBall() {
        XCTAssertEqual(read([toolUse(at(-30)), toolResult(at(-20))]).activity, .working)
    }

    func testAFreshPromptIsWorking() {
        let lines = [endTurn(at(-120)), turnDuration(at(-120)), prompt(at(-10))]
        XCTAssertEqual(read(lines).activity, .working)
    }

    func testBookkeepingAfterAToolUseDoesNotEndTheTurn() {
        let lines = [toolUse(at(-20)), #"{"type":"attachment","timestamp":"\#(at(-19))"}"#]
        XCTAssertEqual(read(lines).activity, .working)
    }

    // MARK: - Staleness

    /// The decay target is the whole point: a session that stopped writing mid-turn was killed, or
    /// slept, or is on a very long tool. None of those is a finished turn, and only a finished
    /// turn writes `turn_duration`.
    func testStaleWorkingDecaysToUnknownNotIdle() {
        let r = read([prompt(at(-600)), toolUse(at(-400))])
        XCTAssertEqual(r.activity, .unknown)
        XCTAssertNotEqual(r.activity, .idle)
    }

    func testWorkingSurvivesUpToTheThreshold() {
        XCTAssertEqual(read([toolUse(at(-299))]).activity, .working)
        XCTAssertEqual(read([toolUse(at(-301))]).activity, .unknown)
    }

    /// An ended turn does not get less true with age.
    func testIdleDoesNotDecay() {
        XCTAssertEqual(read([endTurn(at(-100_000)), turnDuration(at(-100_000))]).activity, .idle)
    }

    func testStaleAfterIsRespected() {
        XCTAssertEqual(read([toolUse(at(-30))], staleAfter: 10).activity, .unknown)
        XCTAssertEqual(read([toolUse(at(-30))], staleAfter: 60).activity, .working)
    }

    /// Without a clock there is nothing to measure staleness against, so the verdict stands rather
    /// than being downgraded on a guess.
    func testWorkingWithNoTimestampsDoesNotDecay() {
        let noClock = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[]}}"#
        let r = read([noClock])
        XCTAssertEqual(r.activity, .working)
        XCTAssertNil(r.lastActivityAt)
    }

    // MARK: - Evidence

    func testLastActivityIsTheNewestClockAnywhereIncludingBookkeeping() {
        let lines = [
            toolUse(at(-300)),
            #"{"type":"pr-link","prNumber":61,"timestamp":"\#(at(-5))"}"#,
        ]
        let r = read(lines, staleAfter: 60)
        // The pr-link decides nothing, but it proves the file is alive — so `working` stands.
        XCTAssertEqual(r.activity, .working)
        XCTAssertEqual(r.lastActivityAt, now.addingTimeInterval(-5))
    }

    func testOutOfOrderTimestampsTakeTheNewest() {
        let lines = [toolUse(at(-10)), toolResult(at(-500))]
        XCTAssertEqual(read(lines).lastActivityAt, now.addingTimeInterval(-10))
    }

    /// A transcript being appended to can be caught mid-line. Half a line is a timing accident,
    /// not a corrupt file, so it is skipped and the entries before it still decide.
    func testTruncatedFinalLineIsSkippedAndTheRestStillDecides() {
        let lines = [prompt(at(-20)), toolUse(at(-10)), #"{"type":"user","mess"#]
        XCTAssertEqual(read(lines).activity, .working)
    }

    func testNothingSignificantStillReportsTheClock() {
        let lines = [#"{"type":"ai-title","aiTitle":"x","timestamp":"\#(at(-42))"}"#]
        let r = read(lines)
        XCTAssertEqual(r.activity, .unknown)
        XCTAssertEqual(r.lastActivityAt, now.addingTimeInterval(-42))
        XCTAssertNil(r.decidedBy)
    }

    // MARK: - Timestamp parsing

    func testISO8601WithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(TranscriptState.date(fromISO8601: "2026-08-19T14:53:36.156Z"))
        XCTAssertNotNil(TranscriptState.date(fromISO8601: "2026-08-19T14:53:36Z"))
        XCTAssertNil(TranscriptState.date(fromISO8601: "yesterday"))
    }
}
