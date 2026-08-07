import XCTest
@testable import DynamicIslandCore

final class CodexHooksConfigTests: XCTestCase {
    func testMissingConfigDefaultsToEnabled() {
        XCTAssertTrue(codexHooksFeatureEnabled(in: nil))
    }

    func testMissingFeatureKeyDefaultsToEnabled() {
        XCTAssertTrue(codexHooksFeatureEnabled(in: "model = \"gpt\"\n"))
        XCTAssertTrue(codexHooksFeatureEnabled(in: "[features]\nfoo = true\n"))
    }

    func testCanonicalKeyWinsOverDeprecatedAlias() {
        let content = "[features]\nhooks = false\ncodex_hooks = true\n"
        XCTAssertFalse(codexHooksFeatureEnabled(in: content))
    }

    func testDeprecatedAliasRemainsReadable() {
        XCTAssertTrue(codexHooksFeatureEnabled(in: "[features]\ncodex_hooks = true\n"))
        XCTAssertFalse(codexHooksFeatureEnabled(in: "[features]\ncodex_hooks = false\n"))
    }

    func testEnableLeavesDefaultEnabledConfigUntouched() {
        let content = "model = \"gpt\"\n"
        XCTAssertEqual(enablingCodexHooks(in: content), content)
    }

    func testEnableFlipsCanonicalFalseAndPreservesComment() {
        let content = "[features]\n  hooks = false # user choice\n"
        XCTAssertEqual(
            enablingCodexHooks(in: content),
            "[features]\n  hooks = true # user choice\n"
        )
    }

    func testEnableMigratesDeprecatedAliasInPlace() {
        let content = "[features]\ncodex_hooks = false # legacy\nother = true\n"
        XCTAssertEqual(
            enablingCodexHooks(in: content),
            "[features]\nhooks = true # legacy\nother = true\n"
        )
    }

    func testEnableRemovesDeprecatedDuplicate() {
        let content = "[features]\ncodex_hooks = false\nhooks = false\n"
        XCTAssertEqual(enablingCodexHooks(in: content), "[features]\nhooks = true\n")
    }

    func testFeatureParsingStopsAtNextSection() {
        let content = "[features]\nfoo = true\n[other]\nhooks = false\n"
        XCTAssertTrue(codexHooksFeatureEnabled(in: content))
    }
}
