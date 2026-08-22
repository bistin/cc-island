import XCTest
@testable import DynamicIslandCore

final class DiffLinesTests: XCTestCase {

    // MARK: - Is this a diff at all

    /// The rule this exists for. A block of markdown bullets is an ordinary detail, and taking a
    /// leading `- ` as authoritative would paint every one of them in delete-red as if the agent
    /// were removing them.
    func testMarkdownBulletsAreNotADiff() {
        let bullets = "- the default one\n- a named server\n- neither"
        XCTAssertFalse(DiffLines.looksLikeDiff(DiffLines.split(bullets)))
        XCTAssertEqual(DiffLines.kinds(of: bullets), [.plain, .plain, .plain])
    }

    /// An addition has no such collision: nothing else in these payloads starts with `+ `.
    func testOneAdditionIsEnoughToMakeItADiff() {
        XCTAssertTrue(DiffLines.looksLikeDiff(DiffLines.split("context\n+ added")))
    }

    func testAnEmptyBlockIsNotADiff() {
        XCTAssertFalse(DiffLines.looksLikeDiff(DiffLines.split("")))
        XCTAssertEqual(DiffLines.kinds(of: ""), [.plain])
    }

    // MARK: - Classification

    func testAdditionsAndRemovalsInsideADiff() {
        XCTAssertEqual(
            DiffLines.kinds(of: "- gone\n+ arrived\n  unchanged"),
            [.removed, .added, .plain]
        )
    }

    /// Classified against the block rather than line by line: whether `- foo` is a deletion
    /// depends on whether the thing it sits in is a diff.
    func testTheSameLineReadsDifferentlyInAndOutOfADiff() {
        XCTAssertEqual(DiffLines.kinds(of: "- foo"), [.plain])
        XCTAssertEqual(DiffLines.kinds(of: "- foo\n+ bar"), [.removed, .added])
    }

    /// A bare `-` is a line of text, not a deletion marker; the space is what makes it one.
    func testTheMarkerNeedsItsSpace() {
        XCTAssertEqual(DiffLines.kinds(of: "-nope\n+ yes"), [.plain, .added])
        XCTAssertEqual(DiffLines.kinds(of: "-\n+ yes"), [.plain, .added])
    }

    /// A diff's empty context line is part of its shape; dropping it would silently reflow what
    /// somebody is being asked to approve.
    func testBlankLinesAreKeptAndCountAsPlain() {
        XCTAssertEqual(DiffLines.kinds(of: "+ a\n\n+ b"), [.added, .plain, .added])
        XCTAssertEqual(DiffLines.split("a\n\nb").count, 3)
    }

    func testOneKindPerLineAlways() {
        for text in ["", "one", "- a\n+ b", "+ a\n\n\n- b", "no markers here"] {
            XCTAssertEqual(DiffLines.kinds(of: text).count, DiffLines.split(text).count, text)
        }
    }

    // MARK: - Compact

    func testAShortBlockIsShownWholeAndHidesNothing() {
        let (lines, hidden) = DiffLines.compact("a\nb\nc")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(hidden, 0, "zero is the caller's cue to draw nothing, not \"+0 more\"")
    }

    func testExactlyTheLimitStillHidesNothing() {
        let text = (1...DiffLines.compactLimit).map(String.init).joined(separator: "\n")
        XCTAssertEqual(DiffLines.compact(text).hidden, 0)
    }

    func testALongBlockKeepsTheHeadAndCountsTheRest() {
        let text = (1...25).map(String.init).joined(separator: "\n")
        let (lines, hidden) = DiffLines.compact(text)
        XCTAssertEqual(lines.count, DiffLines.compactLimit)
        XCTAssertEqual(hidden, 25 - DiffLines.compactLimit)
        XCTAssertEqual(lines.first, "1", "the head, not the tail — a diff reads from the top")
    }

    func testAnExplicitLimitIsHonoured() {
        let (lines, hidden) = DiffLines.compact("a\nb\nc\nd", limit: 2)
        XCTAssertEqual(lines.map(String.init), ["a", "b"])
        XCTAssertEqual(hidden, 2)
    }

    /// The truncated view colours its lines the way the full one would, so a classification made
    /// on the visible slice alone could disagree with itself.
    func testClassificationIsUnchangedByTruncation() {
        let text = (1...20).map { $0 == 15 ? "+ added" : "line \($0)" }.joined(separator: "\n")
        let kinds = DiffLines.kinds(of: text)
        XCTAssertEqual(kinds[0], .plain)
        XCTAssertEqual(kinds[14], .added)
        XCTAssertEqual(DiffLines.compact(text).lines.count, DiffLines.compactLimit)
    }
}
