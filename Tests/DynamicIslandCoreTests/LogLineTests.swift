import XCTest
@testable import DynamicIslandCore

final class LogLineTests: XCTestCase {

    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Milliseconds because the questions this file answers are about order and latency — did the
    /// listener bind before or after the other copy quit — and second resolution collapses exactly
    /// the gaps worth seeing.
    func testAStampToTheMillisecondThenTheMessage() {
        // .125 rather than .123: an eighth is exact in binary, and a fraction that is not comes
        // back a millisecond short from the Double round trip — the test would be measuring
        // floating point, not formatting.
        let at = Date(timeIntervalSince1970: 1_760_000_000.125)
        let line = LogLine.format(at: at, "server: listening", calendar: utc())
        XCTAssertTrue(line.hasSuffix("  server: listening"), line)
        XCTAssertTrue(line.contains(".125"), line)
    }

    func testMonthAndDayAreZeroPaddedSoTheColumnsLineUp() {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 7; c.hour = 4; c.minute = 5; c.second = 6
        let at = utc().date(from: c)!
        XCTAssertTrue(LogLine.format(at: at, "x", calendar: utc()).hasPrefix("03-07 04:05:06."))
    }

    /// One entry is one line. A message with a newline in it would otherwise read as two entries,
    /// the second of which has no timestamp.
    func testNewlinesInAMessageAreFlattened() {
        let line = LogLine.format(at: Date(timeIntervalSince1970: 0), "a\nb", calendar: utc())
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.hasSuffix("a b"))
    }

    // MARK: - Trimming

    /// A log nobody rotates eventually fills a disk.
    func testASmallFileIsLeftAlone() {
        XCTAssertNil(LogLine.trimmed("short\n"))
        XCTAssertNil(LogLine.trimmed(String(repeating: "x", count: LogLine.maximumBytes)))
    }

    func testAnOversizeFileIsCutDown() throws {
        let big = String(repeating: "line\n", count: LogLine.maximumBytes / 5 + 100)
        let trimmed = try XCTUnwrap(LogLine.trimmed(big))
        XCTAssertLessThan(trimmed.utf8.count, big.utf8.count)
        XCTAssertLessThanOrEqual(trimmed.utf8.count, LogLine.maximumBytes)
    }

    /// Half rather than all, so trimming happens rarely instead of on every write once the cap is
    /// reached.
    func testItKeepsRoughlyHalfSoTrimmingIsRare() throws {
        let big = String(repeating: "line\n", count: LogLine.maximumBytes / 5 + 100)
        let trimmed = try XCTUnwrap(LogLine.trimmed(big))
        XCTAssertGreaterThan(trimmed.utf8.count, LogLine.maximumBytes / 4)
    }

    /// The first surviving line would otherwise be a fragment that reads like a corrupt entry
    /// rather than a truncation.
    func testTheCutLandsOnALineBoundaryAndSaysSo() throws {
        let big = String(repeating: "abcdefghij\n", count: LogLine.maximumBytes / 11 + 50)
        let trimmed = try XCTUnwrap(LogLine.trimmed(big))
        XCTAssertTrue(trimmed.hasPrefix("…earlier entries trimmed\n"))
        for line in trimmed.split(separator: "\n").dropFirst() {
            XCTAssertEqual(line, "abcdefghij", "a fragment survived: \(line)")
        }
    }

    func testTheMostRecentEntriesAreTheOnesKept() throws {
        var text = String(repeating: "old\n", count: LogLine.maximumBytes / 4)
        text += "NEWEST\n"
        let trimmed = try XCTUnwrap(LogLine.trimmed(text))
        XCTAssertTrue(trimmed.hasSuffix("NEWEST\n"))
    }

    func testAnExplicitMaximumIsHonoured() {
        XCTAssertNotNil(LogLine.trimmed("aaaa\nbbbb\ncccc\n", maximumBytes: 5))
        XCTAssertNil(LogLine.trimmed("aaaa\n", maximumBytes: 5_000))
    }
}
