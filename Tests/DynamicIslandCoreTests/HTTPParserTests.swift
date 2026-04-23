import XCTest
@testable import DynamicIslandCore

final class HTTPParserTests: XCTestCase {
    private let cap = 1_048_576  // 1 MiB — matches LocalServer's production cap

    // MARK: - Happy paths

    func testCompletePostWithBody() {
        let body = #"{"title":"ok"}"#
        let raw = """
        POST /event HTTP/1.1\r
        Host: 127.0.0.1:9423\r
        Content-Length: \(body.utf8.count)\r
        Content-Type: application/json\r
        \r
        \(body)
        """
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: cap)
        guard case .done(let req) = result else {
            return XCTFail("expected .done, got \(result)")
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/event")
        XCTAssertEqual(req.body, Data(body.utf8))
        XCTAssertEqual(req.headers["content-type"], "application/json")
    }

    func testCompleteGetNoBody() {
        let raw = "GET /response HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: cap)
        guard case .done(let req) = result else {
            return XCTFail("expected .done, got \(result)")
        }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/response")
        XCTAssertTrue(req.body.isEmpty)
    }

    func testMissingContentLengthTreatedAsZero() {
        let raw = "POST /event HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: cap)
        guard case .done(let req) = result else {
            return XCTFail("expected .done, got \(result)")
        }
        XCTAssertTrue(req.body.isEmpty)
    }

    // MARK: - Partial reads

    func testHeadersIncomplete_NeedMore() {
        let raw = "POST /event HTTP/1.1\r\nHost: localhost\r\nContent-Le"
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: cap)
        XCTAssertEqual(result, .needMore)
    }

    func testHeadersCompleteBodyIncomplete_NeedMore() {
        // Content-Length says 10, body only has 3.
        let raw = "POST /event HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc"
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: cap)
        XCTAssertEqual(result, .needMore)
    }

    /// The original bug: header/body split across two receive callbacks.
    /// Parser should see first buffer as `.needMore`, second as `.done`.
    func testSplitBodyArrivesInTwoChunks() {
        let body = #"{"x":1}"#
        let headers = "POST /event HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n"

        let afterHeaders = HTTPParser.parse(Data(headers.utf8), maxTotalBytes: cap)
        XCTAssertEqual(afterHeaders, .needMore)

        var combined = Data(headers.utf8)
        combined.append(Data(body.utf8))
        guard case .done(let req) = HTTPParser.parse(combined, maxTotalBytes: cap) else {
            return XCTFail("expected .done on second chunk")
        }
        XCTAssertEqual(req.body, Data(body.utf8))
    }

    // MARK: - Framing errors

    func testInvalidContentLength_NonNumeric() {
        let raw = "POST /event HTTP/1.1\r\nContent-Length: ten\r\n\r\n"
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: cap)
        if case .invalid = result { return }
        XCTFail("expected .invalid, got \(result)")
    }

    func testInvalidContentLength_Negative() {
        let raw = "POST /event HTTP/1.1\r\nContent-Length: -5\r\n\r\n"
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: cap)
        if case .invalid = result { return }
        XCTFail("expected .invalid, got \(result)")
    }

    func testConflictingDuplicateContentLength_Invalid() {
        let raw = """
        POST /event HTTP/1.1\r
        Content-Length: 10\r
        Content-Length: 20\r
        \r

        """
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: cap)
        if case .invalid = result { return }
        XCTFail("expected .invalid on conflicting Content-Length, got \(result)")
    }

    func testDuplicateContentLengthSameValue_Accepted() {
        // RFC 7230: duplicates are OK if they agree. Body length 0 so
        // there's nothing else to check.
        let raw = """
        POST /event HTTP/1.1\r
        Content-Length: 0\r
        Content-Length: 0\r
        \r

        """
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: cap)
        if case .done = result { return }
        XCTFail("expected .done for identical duplicate Content-Length, got \(result)")
    }

    func testTransferEncodingRejected() {
        // We don't decode chunked, and TE without decoder is a framing hazard.
        let raw = "POST /event HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: cap)
        if case .invalid(let msg) = result, msg.contains("Transfer-Encoding") { return }
        XCTFail("expected .invalid about Transfer-Encoding, got \(result)")
    }

    func testMalformedRequestLine() {
        let raw = "GIBBERISH\r\n\r\n"
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: cap)
        if case .invalid = result { return }
        XCTFail("expected .invalid, got \(result)")
    }

    // MARK: - Oversize

    func testDeclaredOversize_FailsFastBeforeReadingBody() {
        // Content-Length greatly exceeds cap. Parser should reject at
        // header-parse time without requiring caller to buffer the body.
        let raw = "POST /event HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n"
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: 1024)
        XCTAssertEqual(result, .tooLarge)
    }

    func testHeadersAloneExceedCap_TooLarge() {
        // Headers never complete and exceed cap → reject rather than
        // accumulating forever.
        let huge = String(repeating: "X", count: 2000)
        let raw = "POST /event HTTP/1.1\r\nHost: \(huge)"
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: 1024)
        XCTAssertEqual(result, .tooLarge)
    }

    func testExactlyAtCap_Accepted() {
        let body = "x"  // 1 byte
        let headers = "POST /event HTTP/1.1\r\nContent-Length: 1\r\n\r\n"
        let total = Data(headers.utf8).count + 1
        let raw = headers + body
        let result = HTTPParser.parse(Data(raw.utf8), maxTotalBytes: total)
        if case .done = result { return }
        XCTFail("request at exactly cap should parse, got \(result)")
    }
}
