import XCTest
@testable import DynamicIslandCore

final class LoginItemStateTests: XCTestCase {

    // MARK: - loginItemAction

    func testTurningOnRegistersWhenNotRegistered() {
        XCTAssertEqual(loginItemAction(for: .notRegistered, desired: true), .register)
    }

    func testTurningOffUnregistersWhenEnabled() {
        XCTAssertEqual(loginItemAction(for: .enabled, desired: false), .unregister)
    }

    func testAlreadyInDesiredStateDoesNothing() {
        XCTAssertEqual(loginItemAction(for: .enabled, desired: true), .none)
        XCTAssertEqual(loginItemAction(for: .notRegistered, desired: false), .none)
    }

    /// The whole reason the decision lives in a pure function: re-registering
    /// on `requiresApproval` returns success while changing nothing, which
    /// reads as a toggle that springs back for no stated reason.
    func testApprovalVetoIsNotRetriedByRegistering() {
        XCTAssertEqual(loginItemAction(for: .requiresApproval, desired: true), .none)
    }

    /// Turning it off while vetoed still has work to do — drop the
    /// registration entirely so the app stops appearing in Login Items.
    func testTurningOffWhileVetoedStillUnregisters() {
        XCTAssertEqual(loginItemAction(for: .requiresApproval, desired: false), .unregister)
    }

    /// `notFound` is what a never-registered `.app` actually reports on
    /// macOS 26, so turning the toggle on from there must register rather
    /// than treat it as a broken install.
    func testNotFoundRegistersLikeAnyOtherOffState() {
        XCTAssertEqual(loginItemAction(for: .notFound, desired: true), .register)
        XCTAssertEqual(loginItemAction(for: .notFound, desired: false), .none)
    }

    func testUnbundledBuildNeverCallsServiceManagement() {
        XCTAssertEqual(loginItemAction(for: .unavailable, desired: true), .none)
        XCTAssertEqual(loginItemAction(for: .unavailable, desired: false), .none)
    }

    // MARK: - loginItemPresentation

    func testEnabledShowsPlainOnToggle() {
        let state = loginItemPresentation(for: .enabled)
        XCTAssertTrue(state.isOn)
        XCTAssertTrue(state.isInteractive)
        XCTAssertNil(state.message)
        XCTAssertFalse(state.showsSystemSettingsButton)
    }

    func testNotRegisteredShowsPlainOffToggle() {
        let state = loginItemPresentation(for: .notRegistered)
        XCTAssertFalse(state.isOn)
        XCTAssertTrue(state.isInteractive)
        XCTAssertNil(state.message)
    }

    /// Registered but vetoed reads as "off" to the user, because that is the
    /// effect — but it must come with the explanation and the escape hatch.
    func testApprovalVetoReadsOffAndOffersSystemSettings() {
        let state = loginItemPresentation(for: .requiresApproval)
        XCTAssertFalse(state.isOn)
        XCTAssertTrue(state.showsSystemSettingsButton)
        XCTAssertNotNil(state.message)
    }

    /// The toggle reads off while the item is still registered, so the only
    /// flip available is back on — and that is a no-op. A live toggle there
    /// moves and snaps back; the buttons carry the real actions instead.
    func testApprovalVetoDoesNotLeaveALiveToggle() {
        XCTAssertFalse(loginItemPresentation(for: .requiresApproval).isInteractive)
    }

    /// Regression guard for the gap this closes: `.unregister` is reachable
    /// from `requiresApproval` in the action table, but with the toggle
    /// pinned off nothing in the UI could ever ask for `desired: false`.
    /// The button is the only thing that can, so its absence is the bug.
    func testApprovalVetoOffersUnregisterSoTheActionIsReachable() {
        let state = loginItemPresentation(for: .requiresApproval)
        XCTAssertTrue(state.showsUnregisterButton)
        XCTAssertEqual(
            loginItemAction(for: .requiresApproval, desired: false), .unregister,
            "the button sends desired: false — it must still map to unregister"
        )
    }

    /// Everywhere else the toggle can already express "off", so a second
    /// affordance for the same thing would just be clutter.
    func testOnlyTheVetoedStateOffersUnregister() {
        let others: [LoginItemStatus] = [.enabled, .notRegistered, .notFound, .unavailable]
        for status in others {
            XCTAssertFalse(
                loginItemPresentation(for: status).showsUnregisterButton,
                "unexpected unregister button for \(status)"
            )
        }
    }

    /// The menu bar greys its item out via `isInteractive`, so a vetoed item
    /// would go unclickable — taking the explanation and the Remove button
    /// with it. Anything with something to say must stay reachable.
    func testVetoedStateStillHasSomethingToSayWhenNotInteractive() {
        let state = loginItemPresentation(for: .requiresApproval)
        XCTAssertFalse(state.isInteractive)
        XCTAssertTrue(state.isInteractive || state.showsSystemSettingsButton)
    }

    /// A fresh install reports `notFound`, so it must look like a plain
    /// "off" switch — an orange warning there would be a false alarm on
    /// every first launch.
    func testNotFoundLooksLikeAPlainOffToggle() {
        let state = loginItemPresentation(for: .notFound)
        XCTAssertFalse(state.isOn)
        XCTAssertTrue(state.isInteractive)
        XCTAssertNil(state.message)
        XCTAssertFalse(state.showsSystemSettingsButton)
    }

    /// A bare `swift build` binary has no login item at all, so the toggle
    /// is inert rather than failing at click time.
    func testUnbundledBuildDisablesTheToggle() {
        let state = loginItemPresentation(for: .unavailable)
        XCTAssertFalse(state.isOn)
        XCTAssertFalse(state.isInteractive)
        XCTAssertNotNil(state.message)
        XCTAssertFalse(state.showsSystemSettingsButton)
    }

    /// Every status the toggle can render must be reachable without a live
    /// SMAppService — a new case added to the enum should fail here first.
    func testEveryStatusHasAPresentation() {
        let all: [LoginItemStatus] = [
            .enabled, .notRegistered, .requiresApproval, .notFound, .unavailable,
        ]
        for status in all {
            let state = loginItemPresentation(for: status)
            XCTAssertEqual(state.isOn, status == .enabled, "isOn for \(status)")
        }
    }
}
