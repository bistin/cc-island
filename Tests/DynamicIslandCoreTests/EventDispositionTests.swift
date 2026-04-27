import XCTest
@testable import DynamicIslandCore

final class EventDispositionTests: XCTestCase {

    // MARK: - No current event

    func testNoCurrent_anyIncomingShown() {
        for style: EventStyleShape in [.action, .reminder, .other] {
            let disp = decideEventDisposition(
                current: nil, currentExpired: false,
                incoming: snap(title: "x", style: style)
            )
            XCTAssertEqual(disp, .showImmediately, "style \(style)")
        }
    }

    // MARK: - Progress merge wins over everything

    func testSameTitleBothProgress_mergesEvenDuringDecision() {
        let cur = snap(title: "Reading", style: .action, hasProgress: true)
        let incoming = snap(title: "Reading", style: .other, hasProgress: true)
        let disp = decideEventDisposition(
            current: cur, currentExpired: false, incoming: incoming
        )
        XCTAssertEqual(disp, .mergeProgress)
    }

    func testProgressMerge_requiresBothProgress() {
        let cur = snap(title: "Reading", style: .other, hasProgress: true)
        let incoming = snap(title: "Reading", style: .other, hasProgress: false)
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: false, incoming: incoming),
            .showImmediately
        )
    }

    func testProgressMerge_requiresTitleMatch() {
        let cur = snap(title: "Reading", style: .other, hasProgress: true)
        let incoming = snap(title: "Searching", style: .other, hasProgress: true)
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: false, incoming: incoming),
            .showImmediately
        )
    }

    // MARK: - In-decision guard: action style

    func testActionPresent_decisionIncoming_queues() {
        let cur = snap(title: "Permission", style: .action)
        let incoming = snap(title: "Permission", style: .action)
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: false, incoming: incoming),
            .queueAsAction
        )
    }

    func testActionPresent_transientIncoming_differentSession_drops() {
        let cur = snap(title: "Permission", style: .action, sessionID: "S1")
        let incoming = snap(title: "Reading", style: .other, sessionID: "S2")
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: false, incoming: incoming),
            .dropTransient
        )
    }

    func testActionPresent_transientIncoming_sameSessionID_takesOver() {
        let cur = snap(title: "Permission", style: .action, sessionID: "S1")
        let incoming = snap(title: "Reading", style: .other, sessionID: "S1")
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: false, incoming: incoming),
            .showImmediately
        )
    }

    // MARK: - In-decision guard: reminder + replyMode

    func testReminderWithReply_isInDecision() {
        let cur = snap(title: "Waiting", style: .reminder, hasReplyMode: true)
        let incoming = snap(title: "Reading", style: .other)
        // Different session (no IDs, different projects) → drop
        let curWithProject = snap(
            title: "Waiting", style: .reminder, hasReplyMode: true, project: "A"
        )
        let incomingOtherProject = snap(title: "Reading", style: .other, project: "B")
        XCTAssertEqual(
            decideEventDisposition(current: curWithProject, currentExpired: false, incoming: incomingOtherProject),
            .dropTransient
        )
        _ = (cur, incoming)
    }

    func testReminderWithoutReply_isNotInDecision() {
        // Plain reminder (no replyMode) doesn't trigger the guard;
        // the next event shows directly.
        let cur = snap(title: "Note", style: .reminder, hasReplyMode: false)
        let incoming = snap(title: "Reading", style: .other)
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: false, incoming: incoming),
            .showImmediately
        )
    }

    // MARK: - Expired guard releases protection

    func testActionExpired_decisionIncoming_showsInsteadOfQueueing() {
        let cur = snap(title: "Permission", style: .action)
        let incoming = snap(title: "Permission", style: .action)
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: true, incoming: incoming),
            .showImmediately
        )
    }

    func testActionExpired_transientIncoming_shows() {
        let cur = snap(title: "Permission", style: .action)
        let incoming = snap(title: "Reading", style: .other)
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: true, incoming: incoming),
            .showImmediately
        )
    }

    // MARK: - Same-session matching: fallback to (project, agentID)

    func testSameSession_fallsBackToProjectAgentIDWhenNoSessionID() {
        let cur = snap(
            title: "Permission", style: .action,
            sessionID: nil, agentID: "ag-1", project: "demo"
        )
        let incoming = snap(
            title: "Reading", style: .other,
            sessionID: nil, agentID: "ag-1", project: "demo"
        )
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: false, incoming: incoming),
            .showImmediately,  // takeover
            "matching project+agentID counts as same session when no sessionID"
        )
    }

    func testSameSession_differingAgentIDIsCrossSession() {
        let cur = snap(
            title: "Permission", style: .action,
            sessionID: nil, agentID: "ag-1", project: "demo"
        )
        let incoming = snap(
            title: "Reading", style: .other,
            sessionID: nil, agentID: "ag-2", project: "demo"
        )
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: false, incoming: incoming),
            .dropTransient
        )
    }

    func testSameSession_sessionIDWinsOverProject() {
        // Same sessionID + different project still counts as same.
        let cur = snap(
            title: "Permission", style: .action,
            sessionID: "S1", project: "A"
        )
        let incoming = snap(
            title: "Reading", style: .other,
            sessionID: "S1", project: "B"
        )
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: false, incoming: incoming),
            .showImmediately
        )
    }

    // MARK: - Decision style precedence inside guard

    func testActionPresent_reminderWithReplyIncoming_queuesAsAction() {
        let cur = snap(title: "Permission", style: .action)
        let incoming = snap(title: "Waiting", style: .reminder, hasReplyMode: true)
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: false, incoming: incoming),
            .queueAsAction
        )
    }

    func testReminderWithReplyPresent_actionIncoming_queues() {
        let cur = snap(title: "Waiting", style: .reminder, hasReplyMode: true)
        let incoming = snap(title: "Permission", style: .action)
        XCTAssertEqual(
            decideEventDisposition(current: cur, currentExpired: false, incoming: incoming),
            .queueAsAction
        )
    }

    // MARK: - Helpers

    private func snap(
        title: String,
        style: EventStyleShape,
        hasReplyMode: Bool = false,
        hasProgress: Bool = false,
        sessionID: String? = nil,
        agentID: String? = nil,
        project: String? = nil
    ) -> EventSnapshot {
        EventSnapshot(
            title: title, style: style,
            hasReplyMode: hasReplyMode, hasProgress: hasProgress,
            sessionID: sessionID, agentID: agentID, project: project
        )
    }
}
