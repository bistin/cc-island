import XCTest
@testable import IslandHookCore

final class FormatTests: XCTestCase {

    // MARK: - truncate

    func testTruncate_shortString_unchanged() {
        XCTAssertEqual(truncate("hi", 10), "hi")
    }

    func testTruncate_exactlyMax_unchanged() {
        XCTAssertEqual(truncate("abcde", 5), "abcde")
    }

    func testTruncate_longer_addsEllipsis() {
        XCTAssertEqual(truncate("abcdefgh", 5), "abcde…")
    }

    func testTruncate_empty() {
        XCTAssertEqual(truncate("", 5), "")
    }

    // MARK: - basename

    func testBasename_absolutePath() {
        XCTAssertEqual(basename("/Users/bistin/projects/foo.swift"), "foo.swift")
    }

    func testBasename_justName() {
        XCTAssertEqual(basename("file.txt"), "file.txt")
    }

    func testBasename_trailingSlashGone() {
        XCTAssertEqual(basename("/tmp/dir/"), "dir")
    }

    // MARK: - diffLines

    func testDiffLines_empty_returnsEmpty() {
        XCTAssertEqual(diffLines("", prefix: "- "), "")
    }

    func testDiffLines_singleLine() {
        XCTAssertEqual(diffLines("hello", prefix: "+ "), "+ hello")
    }

    func testDiffLines_multiLineAllFit() {
        let input = "one\ntwo\nthree"
        XCTAssertEqual(diffLines(input, prefix: "- "), "- one\n- two\n- three")
    }

    func testDiffLines_exceedsMaxLines_appendsMoreCount() {
        let input = "a\nb\nc\nd\ne\nf\ng"   // 7 lines, default max 5
        let out = diffLines(input, prefix: "+ ")
        XCTAssertTrue(out.contains("+ a"))
        XCTAssertTrue(out.contains("+ e"))
        XCTAssertFalse(out.contains("+ f"))
        XCTAssertTrue(out.hasSuffix("  (+2 more)"))
    }

    func testDiffLines_longLine_truncated() {
        let input = String(repeating: "x", count: 100) // > default maxChars 80
        let out = diffLines(input, prefix: "- ")
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertTrue(out.count < input.count + 2) // sanity: fewer than full len
    }

    // MARK: - buildEditDiff

    func testBuildEditDiff_bothSides() {
        let out = buildEditDiff(old: "let x = 1", new: "let x = 42")
        XCTAssertEqual(out, "- let x = 1\n+ let x = 42")
    }

    func testBuildEditDiff_onlyNew() {
        XCTAssertEqual(buildEditDiff(old: "", new: "new"), "+ new")
    }

    func testBuildEditDiff_onlyOld() {
        XCTAssertEqual(buildEditDiff(old: "gone", new: ""), "- gone")
    }

    func testBuildEditDiff_bothEmpty() {
        XCTAssertEqual(buildEditDiff(old: "", new: ""), "")
    }

    func testBuildEditDiff_multiLineOldNew() {
        let out = buildEditDiff(old: "foo\nbar", new: "FOO\nBAR")
        XCTAssertEqual(out, "- foo\n- bar\n+ FOO\n+ BAR")
    }
}
