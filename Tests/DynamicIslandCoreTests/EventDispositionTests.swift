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

// MARK: - What opens expanded

final class ExpandOnArrivalTests: XCTestCase {

    /// Allow/Deny live in the detail, so the detail *is* the decision.
    func testActionAlwaysOpensExpanded() {
        XCTAssertTrue(shouldOpenExpanded(style: .action, hasDetail: true, hasReplyMode: false))
        XCTAssertTrue(shouldOpenExpanded(style: .action, hasDetail: false, hasReplyMode: false))
    }

    /// A question with its options, a plan with its body, a turn that ended on a question with
    /// the message that ended it — all three are "here is what you would be deciding".
    func testAPulsingReminderWithSomethingToShowOpensExpanded() {
        XCTAssertTrue(shouldOpenExpanded(style: .reminder, hasDetail: true, hasReplyMode: false))
    }

    /// The bare `Notification` ping. Expanding an empty panel would cover the screen to say
    /// nothing.
    func testAReminderWithNothingToShowStaysAsEars() {
        XCTAssertFalse(shouldOpenExpanded(style: .reminder, hasDetail: false, hasReplyMode: false))
    }

    func testQuickRepliesStillOpenExpandedWhateverTheStyle() {
        XCTAssertTrue(shouldOpenExpanded(style: .reminder, hasDetail: false, hasReplyMode: true))
    }

    /// A detail on a passing event is a diff or a preview, not a decision. It grows if clicked.
    func testOrdinaryEventsStayCompactEvenWithADetail() {
        XCTAssertFalse(shouldOpenExpanded(style: .other, hasDetail: true, hasReplyMode: false))
    }
}

// MARK: - Where a tap goes

final class TapDestinationTests: XCTestCase {

    /// The waiting case this exists for: a question whose menu is in the terminal and whose
    /// island shows no buttons. Dismissing it threw away the thing the user was reaching for.
    func testAWaitingReminderSendsTheTapToTheTerminal() {
        XCTAssertTrue(shouldTapJumpToTerminal(
            style: .reminder, hasReplyMode: false, hasTTY: true, clickToTerminalEnabled: true))
    }

    /// Allow/Deny is right there; walking away from a decision is the wrong move.
    func testActionStaysBecauseTheDecisionIsOnTheIsland() {
        XCTAssertFalse(shouldTapJumpToTerminal(
            style: .action, hasReplyMode: false, hasTTY: true, clickToTerminalEnabled: true))
    }

    func testQuickRepliesStayForTheSameReason() {
        XCTAssertFalse(shouldTapJumpToTerminal(
            style: .reminder, hasReplyMode: true, hasTTY: true, clickToTerminalEnabled: true))
    }

    /// Observational events kept their existing jump-to-terminal behaviour.
    func testOrdinaryEventsStillJump() {
        XCTAssertTrue(shouldTapJumpToTerminal(
            style: .other, hasReplyMode: false, hasTTY: true, clickToTerminalEnabled: true))
    }

    /// Nowhere to go, so the tap keeps its old meaning rather than silently doing nothing.
    func testNoTTYMeansNoJump() {
        XCTAssertFalse(shouldTapJumpToTerminal(
            style: .reminder, hasReplyMode: false, hasTTY: false, clickToTerminalEnabled: true))
    }

    func testTheSettingIsHonoured() {
        XCTAssertFalse(shouldTapJumpToTerminal(
            style: .reminder, hasReplyMode: false, hasTTY: true, clickToTerminalEnabled: false))
        XCTAssertFalse(shouldTapJumpToTerminal(
            style: .other, hasReplyMode: false, hasTTY: true, clickToTerminalEnabled: false))
    }
}

// MARK: - A persistent reminder is not something to bury

final class PersistentReminderProtectionTests: XCTestCase {

    private func waiting(session: String? = nil, project: String? = nil) -> EventSnapshot {
        EventSnapshot(title: "Waiting for you", style: .reminder, hasReplyMode: false,
                      isPersistent: true, hasProgress: false,
                      sessionID: session, agentID: nil, project: project)
    }

    private func passing(session: String? = nil, project: String? = nil) -> EventSnapshot {
        EventSnapshot(title: "Terminal", style: .other, hasReplyMode: false,
                      isPersistent: false, hasProgress: false,
                      sessionID: session, agentID: nil, project: project)
    }

    /// The hole this closes. An `AskUserQuestion` waiting on somebody is the same claim on their
    /// attention as an Allow/Deny, and before this the very next tool call from *any* session
    /// replaced it — the question vanished from the island while it was still on screen in the
    /// terminal.
    func testAnotherSessionsToolCallDoesNotBuryIt() {
        XCTAssertEqual(
            decideEventDisposition(current: waiting(session: "A"), currentExpired: false,
                                   incoming: passing(session: "B")),
            .dropTransient
        )
    }

    /// Same session moving on to its next tool is a session whose question got answered. This is
    /// also the clearing path for a tool the user cancelled, which never reaches `PostToolUse`.
    func testItsOwnSessionMovingOnStillTakesOver() {
        XCTAssertEqual(
            decideEventDisposition(current: waiting(session: "A"), currentExpired: false,
                                   incoming: passing(session: "A")),
            .showImmediately
        )
    }

    func testTwoWaitingSessionsQueueRatherThanOverwrite() {
        XCTAssertEqual(
            decideEventDisposition(current: waiting(session: "A"), currentExpired: false,
                                   incoming: waiting(session: "B")),
            .queueAsAction
        )
    }

    /// A permission dialog must still be able to interrupt — it has a long-polling hook behind it.
    func testAPermissionRequestStillQueuesBehindIt() {
        let permission = EventSnapshot(title: "Permission", style: .action, hasReplyMode: false,
                                       isPersistent: true, hasProgress: false,
                                       sessionID: "B", agentID: nil, project: nil)
        XCTAssertEqual(
            decideEventDisposition(current: waiting(session: "A"), currentExpired: false,
                                   incoming: permission),
            .queueAsAction
        )
    }

    /// The bare `Notification` ping is not persistent and keeps its old, unprotected behaviour —
    /// it is a ping, not a wait.
    func testANonPersistentReminderIsStillReplaceable() {
        let ping = EventSnapshot(title: "Claude Code", style: .reminder, hasReplyMode: false,
                                 isPersistent: false, hasProgress: false,
                                 sessionID: "A", agentID: nil, project: nil)
        XCTAssertEqual(
            decideEventDisposition(current: ping, currentExpired: false,
                                   incoming: passing(session: "B")),
            .showImmediately
        )
    }

    /// Falls back to (project, agentID) when neither carries a session id.
    func testCrossProjectNoiseIsDroppedWithoutSessionIDs() {
        XCTAssertEqual(
            decideEventDisposition(current: waiting(project: "island"), currentExpired: false,
                                   incoming: passing(project: "other")),
            .dropTransient
        )
    }
}

// MARK: - The panel has to be tall enough for what is in it

final class ExpandedPanelHeightTests: XCTestCase {

    /// The bug this exists for. An `action` stacks two rows of controls under the detail —
    /// Allow/Deny, and the jump-to-terminal row — and none of that was in the sum, so the space
    /// came out of the detail. The detail is a ScrollView with a maximum and no minimum, which
    /// does not clip when squeezed: it collapses. The dialog looked deliberate and the diff it
    /// exists to show was simply absent.
    func testDecisionRowsAreCountedRatherThanTakenOutOfTheDetail() {
        let withButtons = expandedPanelExtraHeight(sessionRows: 0, detailLines: 3, decisionRows: 2)
        let without = expandedPanelExtraHeight(sessionRows: 0, detailLines: 3, decisionRows: 0)
        XCTAssertGreaterThan(withButtons, without)
        XCTAssertEqual(withButtons - without, 104, "two 44pt tap targets plus their gaps")
    }

    /// The base already covers about three lines, so a short detail costs nothing extra — that
    /// part was never wrong and should not start growing the panel now.
    func testAShortDetailStillCostsNothing() {
        XCTAssertEqual(expandedPanelExtraHeight(sessionRows: 0, detailLines: 3, decisionRows: 0), 0)
        XCTAssertEqual(expandedPanelExtraHeight(sessionRows: 0, detailLines: 0, decisionRows: 0), 0)
    }

    func testATallDetailGrowsThePanelLineByLine() {
        XCTAssertEqual(expandedPanelExtraHeight(sessionRows: 0, detailLines: 5, decisionRows: 0), 28)
    }

    /// One session is just the event; the tree only earns its space once there is something to
    /// compare.
    func testTheSessionTreeOnlyCostsWhenThereIsMoreThanOne() {
        XCTAssertEqual(expandedPanelExtraHeight(sessionRows: 1, detailLines: 0, decisionRows: 0), 0)
        XCTAssertGreaterThan(expandedPanelExtraHeight(sessionRows: 2, detailLines: 0, decisionRows: 0), 0)
    }

    /// A permission dialog on a busy machine is all three at once, and the panel has to fit the
    /// sum rather than whichever one the layout happened to be written for.
    func testTheThreeAddUpRatherThanCompeting() {
        let all = expandedPanelExtraHeight(sessionRows: 3, detailLines: 8, decisionRows: 2)
        let tree = expandedPanelExtraHeight(sessionRows: 3, detailLines: 0, decisionRows: 0)
        let detail = expandedPanelExtraHeight(sessionRows: 0, detailLines: 8, decisionRows: 0)
        let rows = expandedPanelExtraHeight(sessionRows: 0, detailLines: 0, decisionRows: 2)
        XCTAssertEqual(all, tree + detail + rows)
    }

    /// Nothing here should ever shrink the panel below its base.
    func testTheExtraIsNeverNegative() {
        XCTAssertGreaterThanOrEqual(
            expandedPanelExtraHeight(sessionRows: -1, detailLines: -5, decisionRows: -2), 0)
    }
}

// MARK: - The session tree has a ceiling

final class SessionRowBudgetTests: XCTestCase {

    /// The case that prompted this: fourteen rows made a panel taller than the screen, with its
    /// last rows cut off — including the question the user was being asked, pushed away by agents
    /// that had already finished.
    func testFourteenRowsDoNotDrawFourteen() {
        let (shown, hidden) = sessionRowsToShow(total: 14)
        XCTAssertEqual(shown, 4)
        XCTAssertEqual(hidden, 10)
        XCTAssertEqual(shown + 1, 5, "the drawn rows plus the summary line stay within the limit")
    }

    /// A tree that fits is drawn whole; nothing is summarised away for the sake of symmetry.
    func testASmallTreeIsDrawnWhole() {
        for n in 0...5 {
            let (shown, hidden) = sessionRowsToShow(total: n)
            XCTAssertEqual(shown, n, "total \(n)")
            XCTAssertEqual(hidden, 0, "total \(n)")
        }
    }

    /// One past the limit still costs a row for the summary — which means six rows draw four and
    /// say "and 2 more" rather than drawing five. Stated because it looks off by one until you
    /// remember the summary is itself a row.
    func testOnePastTheLimitGivesUpARowToTheSummary() {
        let (shown, hidden) = sessionRowsToShow(total: 6)
        XCTAssertEqual(shown, 4)
        XCTAssertEqual(hidden, 2)
    }

    func testEverythingIsAccountedFor() {
        for n in 0...40 {
            let (shown, hidden) = sessionRowsToShow(total: n)
            XCTAssertEqual(shown + hidden, n, "total \(n) — rows must not be lost or invented")
        }
    }

    /// However many arrive, the panel's row count is bounded — which is the whole point, given
    /// what put fourteen there was a close path that never fired.
    func testTheDrawnCountIsBoundedWhateverArrives() {
        for n in [50, 500, 5000] {
            let (shown, hidden) = sessionRowsToShow(total: n)
            XCTAssertLessThanOrEqual(shown + (hidden > 0 ? 1 : 0), 5)
        }
    }

    func testAnExplicitLimitIsHonoured() {
        XCTAssertEqual(sessionRowsToShow(total: 10, limit: 3).shown, 2)
        XCTAssertEqual(sessionRowsToShow(total: 10, limit: 3).hidden, 8)
    }

    func testNegativeAndZeroAreNotNegative() {
        XCTAssertEqual(sessionRowsToShow(total: 0).shown, 0)
        XCTAssertEqual(sessionRowsToShow(total: -3).shown, 0)
    }
}

// MARK: - Tapping the expanded panel

final class ExpandedTapActionTests: XCTestCase {

    /// The drift this exists to prevent: the notch panel learned to take the tap to the terminal
    /// and the capsule did not, so on a display without a notch the panel never reached the
    /// session it was pointing at. One decision, one place, checkable without a window.
    func testAPointerPanelFollowsItsPointer() {
        XCTAssertEqual(
            expandedTapAction(style: .reminder, hasReplyMode: false, canJumpToTerminal: true),
            .jumpToTerminal)
    }

    /// Collapsing sets a dismiss timer that would strand a hook still long-polling for the answer,
    /// so a tap on a decision does nothing rather than something tidy.
    func testADecisionSwallowsTheTap() {
        XCTAssertEqual(
            expandedTapAction(style: .action, hasReplyMode: false, canJumpToTerminal: true),
            .ignore)
        XCTAssertEqual(
            expandedTapAction(style: .reminder, hasReplyMode: true, canJumpToTerminal: true),
            .ignore)
    }

    /// Being mid-decision wins over having somewhere to go — otherwise a tap would walk away from
    /// the buttons it was aimed at.
    func testIgnoreWinsOverJumping() {
        for canJump in [true, false] {
            XCTAssertEqual(
                expandedTapAction(style: .action, hasReplyMode: true, canJumpToTerminal: canJump),
                .ignore)
        }
    }

    func testNowhereToGoMeansFoldItAway() {
        XCTAssertEqual(
            expandedTapAction(style: .reminder, hasReplyMode: false, canJumpToTerminal: false),
            .collapse)
        XCTAssertEqual(
            expandedTapAction(style: .other, hasReplyMode: false, canJumpToTerminal: false),
            .collapse)
    }

    func testAnOrdinaryEventWithATerminalStillJumps() {
        XCTAssertEqual(
            expandedTapAction(style: .other, hasReplyMode: false, canJumpToTerminal: true),
            .jumpToTerminal)
    }
}
