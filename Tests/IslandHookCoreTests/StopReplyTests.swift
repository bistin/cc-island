import XCTest
@testable import IslandHookCore

// MARK: - containsQuestion

final class ContainsQuestionTests: XCTestCase {
    func test_emptyString_returnsFalse() {
        XCTAssertFalse(containsQuestion(""))
    }

    func test_pureStatement_returnsFalse() {
        XCTAssertFalse(containsQuestion("All checks passed."))
    }

    func test_trailingASCIIQuestionMark_returnsTrue() {
        XCTAssertTrue(containsQuestion("Should I proceed?"))
    }

    func test_trailingFullwidthQuestionMark_returnsTrue() {
        XCTAssertTrue(containsQuestion("該怎麼辦？"))
    }

    /// xero7689's specific case from #20 review: question is embedded
    /// before a trailing statement. `extractLastQuestion` (#9 v1.5.0)
    /// would miss this because the last sentence isn't terminated by `?`.
    func test_embeddedQuestionFollowedByStatement_returnsTrue() {
        XCTAssertTrue(containsQuestion("你覺得呢？如果不這樣做的話系統可能會有問題。"))
    }

    func test_questionInMiddle_returnsTrue() {
        XCTAssertTrue(containsQuestion("Earlier I noted X. Should I proceed? Then I continued."))
    }

    /// Acknowledged false positive — the bias is toward showing reply UI.
    /// Cost of false positive: one second of "no buttons appeared, dismiss".
    /// Cost of false negative: the Cmd-Tab pain we're trying to remove.
    func test_ternaryOperator_returnsTrueAcceptedFalsePositive() {
        XCTAssertTrue(containsQuestion("Use the ?: operator here."))
    }
}

// MARK: - extractYesNoOptions

final class ExtractYesNoOptionsTests: XCTestCase {
    func test_yesNoSlash_returnsYesNo() {
        XCTAssertEqual(extractYesNoOptions(from: "Continue? yes/no"), ["Yes", "No"])
    }

    func test_yesNoSlashUppercase_returnsYesNo() {
        XCTAssertEqual(extractYesNoOptions(from: "Continue? YES/NO"), ["Yes", "No"])
    }

    func test_noYesSlash_returnsYesNo() {
        XCTAssertEqual(extractYesNoOptions(from: "Continue? no/yes"), ["Yes", "No"])
    }

    func test_yNSlash_returnsYesNo() {
        XCTAssertEqual(extractYesNoOptions(from: "OK? Y/N"), ["Yes", "No"])
    }

    func test_yNSlashLowercase_returnsYesNo() {
        XCTAssertEqual(extractYesNoOptions(from: "OK? y/n"), ["Yes", "No"])
    }

    func test_fullwidthSlash_returnsYesNo() {
        XCTAssertEqual(extractYesNoOptions(from: "繼續嗎？yes／no"), ["Yes", "No"])
    }

    func test_chineseYesNoHalfwidthSlash_returnsChinese() {
        XCTAssertEqual(extractYesNoOptions(from: "繼續嗎？是/否"), ["是", "否"])
    }

    func test_chineseYesNoFullwidthSlash_returnsChinese() {
        XCTAssertEqual(extractYesNoOptions(from: "繼續嗎？是／否"), ["是", "否"])
    }

    func test_chineseNoYes_returnsChinese() {
        XCTAssertEqual(extractYesNoOptions(from: "繼續嗎？否/是"), ["是", "否"])
    }

    func test_AorB_returnsNil() {
        // "Should I use option A or B?" doesn't follow our recognised
        // pattern. Returning nil → no buttons, falls back to text field
        // (Phase 2). Don't synthesise wrong labels.
        XCTAssertNil(extractYesNoOptions(from: "Should I use option A or B?"))
    }

    func test_plainQuestion_returnsNil() {
        XCTAssertNil(extractYesNoOptions(from: "What should I do?"))
    }

    func test_emptyString_returnsNil() {
        XCTAssertNil(extractYesNoOptions(from: ""))
    }

    func test_yesNoAsSeparateWords_returnsNil() {
        // "yes" and "no" appear but not as the slash-separated pattern.
        XCTAssertNil(extractYesNoOptions(from: "yes I think no is wrong"))
    }
}

// MARK: - encodeStopBlockResponse

final class EncodeStopBlockResponseTests: XCTestCase {
    /// Round-trip the encoded JSON through JSONSerialization to verify the
    /// reason survives intact — the only contract that matters for Phase 0.
    /// Uses `[String: String]` parse since both fields are strings.
    private func parsedReason(_ encoded: String) -> String? {
        guard let data = encoded.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return dict["reason"]
    }

    func test_decisionFieldIsBlock() throws {
        let encoded = encodeStopBlockResponse(reason: "anything")
        let data = try XCTUnwrap(encoded.data(using: .utf8))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(dict["decision"], "block")
    }

    func test_asciiReason_roundTrips() {
        XCTAssertEqual(
            parsedReason(encodeStopBlockResponse(reason: "do this thing")),
            "do this thing"
        )
    }

    func test_chineseReason_roundTrips() {
        XCTAssertEqual(
            parsedReason(encodeStopBlockResponse(reason: "請繼續這個任務")),
            "請繼續這個任務"
        )
    }

    func test_emojiReason_roundTrips() {
        XCTAssertEqual(
            parsedReason(encodeStopBlockResponse(reason: "🎉🚀 finished")),
            "🎉🚀 finished"
        )
    }

    func test_doubleQuotes_areEscaped() {
        XCTAssertEqual(
            parsedReason(encodeStopBlockResponse(reason: #"She said "hi""#)),
            #"She said "hi""#
        )
    }

    func test_newlinesAndTabs_roundTrip() {
        XCTAssertEqual(
            parsedReason(encodeStopBlockResponse(reason: "line1\nline2\tcol2")),
            "line1\nline2\tcol2"
        )
    }

    func test_longReason_notTruncated() {
        let reason = String(repeating: "x", count: 5000)
        XCTAssertEqual(
            parsedReason(encodeStopBlockResponse(reason: reason))?.count,
            5000
        )
    }

    func test_emptyReason_roundTrips() {
        XCTAssertEqual(
            parsedReason(encodeStopBlockResponse(reason: "")),
            ""
        )
    }

    func test_backslashes_roundTrip() {
        XCTAssertEqual(
            parsedReason(encodeStopBlockResponse(reason: #"path\to\file"#)),
            #"path\to\file"#
        )
    }
}

// MARK: - StopReplyTimeoutSeconds

final class StopReplyTimeoutTests: XCTestCase {
    /// Sanity floor / ceiling — actual value is a tunable constant. Anything
    /// outside this range is almost certainly a typo. Real validation comes
    /// from usage feedback (issue #20 marks 30s as a first guess).
    func test_constantInReasonableRange() {
        XCTAssertGreaterThanOrEqual(StopReplyTimeoutSeconds, 10)
        XCTAssertLessThanOrEqual(StopReplyTimeoutSeconds, 120)
    }
}
