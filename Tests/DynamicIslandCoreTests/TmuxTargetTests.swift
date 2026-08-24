import XCTest
@testable import DynamicIslandCore

final class TmuxTargetTests: XCTestCase {

    // Captured from a live tmux server rather than invented — see the format constants, which the
    // app sends verbatim.
    private let panes = """
    /dev/ttys005|%0|probe
    /dev/ttys009|%3|work
    /dev/ttys011|%4|work
    """
    private let clients = """
    probe|/dev/ttys006
    work|/dev/ttys012
    """

    // MARK: - The bug this exists for

    /// The whole point: the tty the hook reports is the pane's, and the tty a terminal emulator
    /// knows the tab by is the client's. They are different numbers.
    func testPaneTTYResolvesToADifferentClientTTY() {
        let t = TmuxTargetResolver.resolve(tty: "/dev/ttys005", panes: panes, clients: clients)
        XCTAssertEqual(t?.paneID, "%0")
        XCTAssertEqual(t?.sessionName, "probe")
        XCTAssertEqual(t?.clientTTY, "/dev/ttys006")
        XCTAssertNotEqual(t?.clientTTY, "/dev/ttys005")
    }

    /// Two panes of one session share its client, because the client is attached to the session.
    func testPanesInOneSessionShareTheClientTTY() {
        let a = TmuxTargetResolver.resolve(tty: "/dev/ttys009", panes: panes, clients: clients)
        let b = TmuxTargetResolver.resolve(tty: "/dev/ttys011", panes: panes, clients: clients)
        XCTAssertEqual(a?.paneID, "%3")
        XCTAssertEqual(b?.paneID, "%4")
        XCTAssertEqual(a?.clientTTY, "/dev/ttys012")
        XCTAssertEqual(b?.clientTTY, "/dev/ttys012")
    }

    // MARK: - Not tmux at all

    /// The ordinary case for somebody running Claude Code straight in a terminal. The caller then
    /// carries on with the tty it already had, so this must be nil rather than a wrong pane.
    func testATTYThatIsNotAPaneResolvesToNothing() {
        XCTAssertNil(TmuxTargetResolver.resolve(tty: "/dev/ttys099", panes: panes, clients: clients))
    }

    func testNoTmuxServerMeansNoTarget() {
        XCTAssertNil(TmuxTargetResolver.resolve(tty: "/dev/ttys005", panes: "", clients: ""))
    }

    func testEmptyTTYResolvesToNothing() {
        XCTAssertNil(TmuxTargetResolver.resolve(tty: "", panes: panes, clients: clients))
        XCTAssertNil(TmuxTargetResolver.resolve(tty: "   ", panes: panes, clients: clients))
    }

    // MARK: - Detached

    /// A detached session is still somewhere the pane can be selected; there is simply no window
    /// showing it. The pane must still come back, or selecting would be skipped for no reason.
    func testDetachedSessionStillYieldsThePane() {
        let t = TmuxTargetResolver.resolve(tty: "/dev/ttys005", panes: panes, clients: "")
        XCTAssertEqual(t?.paneID, "%0")
        XCTAssertNil(t?.clientTTY)
    }

    func testClientForADifferentSessionIsNotBorrowed() {
        let t = TmuxTargetResolver.resolve(tty: "/dev/ttys005", panes: panes, clients: "work|/dev/ttys012")
        XCTAssertEqual(t?.paneID, "%0")
        XCTAssertNil(t?.clientTTY)
    }

    // MARK: - Shapes

    /// tmux prints the full path; `ps` prints the bare name. A comparison that took either side
    /// literally would match nothing while looking perfectly reasonable.
    func testTTYIsComparedByDeviceNameNotByLiteralString() {
        XCTAssertEqual(TmuxTargetResolver.resolve(tty: "ttys005", panes: panes, clients: clients)?.paneID, "%0")
        XCTAssertEqual(TmuxTargetResolver.resolve(tty: "/dev/ttys005", panes: panes, clients: clients)?.paneID, "%0")
    }

    func testMalformedLinesAreSkippedAndTheRestStillResolve() {
        let messy = """
        garbage without separators
        /dev/ttys005|%0
        /dev/ttys005|%7|probe
        """
        XCTAssertEqual(TmuxTargetResolver.resolve(tty: "/dev/ttys005", panes: messy, clients: clients)?.paneID, "%7")
    }

    func testAPaneWithNoIDIsNotATarget() {
        XCTAssertNil(TmuxTargetResolver.resolve(tty: "/dev/ttys005", panes: "/dev/ttys005||probe", clients: clients))
    }

    /// Several clients on one session is legal and there is no basis for preferring either, so the
    /// first wins — stated as a rule rather than left to whatever the loop happened to do.
    func testFirstClientWinsWhenASessionHasSeveral() {
        let many = "probe|/dev/ttys006\nprobe|/dev/ttys007"
        XCTAssertEqual(TmuxTargetResolver.resolve(tty: "/dev/ttys005", panes: panes, clients: many)?.clientTTY,
                       "/dev/ttys006")
    }

    func testSessionNamesWithUnusualCharacters() {
        let p = "/dev/ttys005|%0|my work: 2\n"
        let c = "my work: 2|/dev/ttys006\n"
        let t = TmuxTargetResolver.resolve(tty: "/dev/ttys005", panes: p, clients: c)
        XCTAssertEqual(t?.sessionName, "my work: 2")
        XCTAssertEqual(t?.clientTTY, "/dev/ttys006")
    }

    // MARK: - The formats the app sends

    /// These strings are what production passes to tmux. Pinning them here means a change in one
    /// place and not the other fails a test rather than showing up as "it stopped working".
    func testFormatsAreTheOnesTheParserExpects() {
        XCTAssertEqual(TmuxTargetResolver.paneFormat, "#{pane_tty}|#{pane_id}|#{session_name}")
        XCTAssertEqual(TmuxTargetResolver.clientFormat, "#{client_session}|#{client_tty}")
    }

    func testNormalizeStripsOnlyTheDevPrefix() {
        XCTAssertEqual(TmuxTargetResolver.normalize("/dev/ttys005"), "ttys005")
        XCTAssertEqual(TmuxTargetResolver.normalize("ttys005"), "ttys005")
        XCTAssertEqual(TmuxTargetResolver.normalize(" /dev/pts/3 "), "pts/3")
    }
}

// MARK: - Three outcomes, not two

final class TmuxRevealOutcomeTests: XCTestCase {

    /// The bug. A detached session's pane still gets selected — that is why every pane on the
    /// server is listed rather than the attached session's — but the emulator tty is nil for one,
    /// and an optional return made that indistinguishable from "no pane found". Selecting a pane
    /// on a detached server reported not finding one, while having just moved the selection.
    func testASelectedPaneWithNoClientIsStillASelection() {
        let detached = TmuxRevealOutcome.selected(emulatorTTY: nil)
        XCTAssertTrue(detached.didSelect)
        XCTAssertNotEqual(detached, .notAPane)
    }

    func testEachOutcomeReadsDifferently() {
        let said = [
            describeTmuxReveal(.notAPane, requested: "/dev/ttys003"),
            describeTmuxReveal(.selected(emulatorTTY: "/dev/ttys007"), requested: "/dev/ttys003"),
            describeTmuxReveal(.selected(emulatorTTY: nil), requested: "/dev/ttys003"),
        ]
        XCTAssertEqual(Set(said).count, 3, "three outcomes that print as fewer is the bug itself")
    }

    func testTheNotAPaneLineNamesTheTTYItLookedFor() {
        XCTAssertTrue(describeTmuxReveal(.notAPane, requested: "/dev/ttys003")
            .contains("/dev/ttys003"))
    }

    func testADetachedSelectionDoesNotClaimAnEmulator() {
        let line = describeTmuxReveal(.selected(emulatorTTY: nil), requested: "/dev/ttys003")
        XCTAssertTrue(line.contains("no client attached"), line)
        XCTAssertFalse(line.contains("emulator tty"), line)
    }

    /// No prefix: the same sentence goes to the log behind "activate: " and to `--reveal-tty`
    /// behind "tmux: ", and one of those used to read "tmux: tmux selected the pane".
    func testTheSentenceCarriesNoPrefixOfItsOwn() {
        for outcome: TmuxRevealOutcome in [.notAPane, .selected(emulatorTTY: "/dev/ttys007"),
                                           .selected(emulatorTTY: nil)] {
            let line = describeTmuxReveal(outcome, requested: "/dev/ttys003")
            XCTAssertFalse(line.hasPrefix("tmux:"), line)
            XCTAssertFalse(line.hasPrefix("activate:"), line)
        }
    }

    // MARK: - Which tty goes on to AppleScript

    func testAnAttachedSelectionHandsOverTheEmulatorTTY() {
        XCTAssertEqual(
            TmuxRevealOutcome.selected(emulatorTTY: "/dev/ttys007").effectiveTTY(requested: "/dev/ttys003"),
            "/dev/ttys007", "the tty an emulator knows the tab by — the whole point of the join")
    }

    /// Nothing for AppleScript to match, so the original is carried on with; tmux already did its
    /// part and the fallback should not be handed a nil.
    func testADetachedSelectionFallsBackToTheRequestedTTY() {
        XCTAssertEqual(
            TmuxRevealOutcome.selected(emulatorTTY: nil).effectiveTTY(requested: "/dev/ttys003"),
            "/dev/ttys003")
    }

    func testNotAPaneCarriesOnWithWhatItWasGiven() {
        XCTAssertEqual(TmuxRevealOutcome.notAPane.effectiveTTY(requested: "/dev/ttys003"),
                       "/dev/ttys003")
        XCTAssertFalse(TmuxRevealOutcome.notAPane.didSelect)
    }
}
