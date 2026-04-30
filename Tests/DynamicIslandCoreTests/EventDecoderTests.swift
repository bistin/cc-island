import XCTest
@testable import DynamicIslandCore

final class EventDecoderTests: XCTestCase {

    // MARK: - decodeQuickReplies

    func testQuickReplies_nilWhenMissing() {
        XCTAssertNil(decodeQuickReplies(from: nil))
    }

    func testQuickReplies_nilWhenNotArray() {
        XCTAssertNil(decodeQuickReplies(from: "Yes,No"))
        XCTAssertNil(decodeQuickReplies(from: 42))
    }

    func testQuickReplies_nilWhenEmpty() {
        XCTAssertNil(decodeQuickReplies(from: [Any]()))
    }

    func testQuickReplies_returnsStringsAsIsWhenSmall() {
        XCTAssertEqual(decodeQuickReplies(from: ["Yes", "No"]), ["Yes", "No"])
    }

    func testQuickReplies_capsAtThree() {
        let raw: [Any] = ["A", "B", "C", "D", "E"]
        XCTAssertEqual(decodeQuickReplies(from: raw), ["A", "B", "C"])
    }

    func testQuickReplies_truncatesLongLabels() {
        let raw: [Any] = [String(repeating: "x", count: 30)]
        XCTAssertEqual(decodeQuickReplies(from: raw)?.first?.count, 20)
    }

    func testQuickReplies_dropsNonStringEntries() {
        let raw: [Any] = ["Yes", 42, "No", true]
        XCTAssertEqual(decodeQuickReplies(from: raw), ["Yes", "No"])
    }

    func testQuickReplies_nilIfAllEntriesDropped() {
        let raw: [Any] = [42, true, [String: Any]()]
        XCTAssertNil(decodeQuickReplies(from: raw))
    }

    // MARK: - decodeFreeformReplyable

    func testFreeformReplyable_trueOnlyForExplicitTrue() {
        XCTAssertTrue(decodeFreeformReplyable(from: true))
    }

    func testFreeformReplyable_falseForFalse() {
        XCTAssertFalse(decodeFreeformReplyable(from: false))
    }

    func testFreeformReplyable_falseForMissing() {
        XCTAssertFalse(decodeFreeformReplyable(from: nil))
    }

    func testFreeformReplyable_falseForNonBool() {
        XCTAssertFalse(decodeFreeformReplyable(from: "true"))
        XCTAssertFalse(decodeFreeformReplyable(from: 1))
        XCTAssertFalse(decodeFreeformReplyable(from: "1"))
    }

    // MARK: - decodeSuggestedRuleFields

    func testSuggestedRule_returnsTupleWhenBothFieldsPresent() {
        let json: [String: Any] = [
            "suggested_rule": [
                "toolName": "Bash",
                "ruleContent": "git status *",
            ],
        ]
        let r = decodeSuggestedRuleFields(from: json)
        XCTAssertEqual(r?.toolName, "Bash")
        XCTAssertEqual(r?.ruleContent, "git status *")
    }

    func testSuggestedRule_nilWhenMissing() {
        XCTAssertNil(decodeSuggestedRuleFields(from: [:]))
    }

    func testSuggestedRule_nilWhenToolNameMissing() {
        let json: [String: Any] = [
            "suggested_rule": ["ruleContent": "git status *"],
        ]
        XCTAssertNil(decodeSuggestedRuleFields(from: json))
    }

    func testSuggestedRule_nilWhenRuleContentMissing() {
        let json: [String: Any] = [
            "suggested_rule": ["toolName": "Bash"],
        ]
        XCTAssertNil(decodeSuggestedRuleFields(from: json))
    }

    func testSuggestedRule_nilWhenFieldsNotStrings() {
        let json: [String: Any] = [
            "suggested_rule": [
                "toolName": 42,
                "ruleContent": true,
            ],
        ]
        XCTAssertNil(decodeSuggestedRuleFields(from: json))
    }
}
