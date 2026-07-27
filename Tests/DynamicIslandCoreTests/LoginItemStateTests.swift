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
        XCTAssertTrue(state.isInteractive)
        XCTAssertTrue(state.showsSystemSettingsButton)
        XCTAssertNotNil(state.message)
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
