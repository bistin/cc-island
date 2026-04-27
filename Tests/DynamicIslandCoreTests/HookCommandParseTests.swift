import XCTest
@testable import DynamicIslandCore

final class HookCommandParseTests: XCTestCase {

    // MARK: - Bare path passthrough

    func testBarePath_returnsAsIs() {
        XCTAssertEqual(
            stripCommandPrefix("/Users/foo/.claude/hooks/dynamic-island-hook"),
            "/Users/foo/.claude/hooks/dynamic-island-hook"
        )
    }

    // MARK: - Quote stripping

    func testSingleQuoted_stripsOuterQuotes() {
        XCTAssertEqual(
            stripCommandPrefix("'/Users/foo/.claude/hooks/dynamic-island-hook'"),
            "/Users/foo/.claude/hooks/dynamic-island-hook"
        )
    }

    func testDoubleQuoted_stripsOuterQuotes() {
        XCTAssertEqual(
            stripCommandPrefix(#""/Users/foo/.claude/hooks/dynamic-island-hook""#),
            "/Users/foo/.claude/hooks/dynamic-island-hook"
        )
    }

    func testMismatchedQuotes_passesThrough() {
        // Don't try to be clever — leave malformed strings alone so a
        // matching test against a known-canonical path simply fails.
        XCTAssertEqual(
            stripCommandPrefix("'/path/no-trailing-quote"),
            "'/path/no-trailing-quote"
        )
    }

    // MARK: - Env prefix stripping

    func testSingleEnvPrefix_stripped() {
        XCTAssertEqual(
            stripCommandPrefix("CC_ISLAND_STOP_TIMEOUT=30 '/Users/foo/.claude/hooks/dynamic-island-hook'"),
            "/Users/foo/.claude/hooks/dynamic-island-hook"
        )
    }

    func testMultipleEnvPrefixes_allStripped() {
        XCTAssertEqual(
            stripCommandPrefix("CC_ISLAND_INLINE_REPLY=1 CC_ISLAND_STOP_TIMEOUT=30 '/Users/foo/.claude/hooks/dynamic-island-hook'"),
            "/Users/foo/.claude/hooks/dynamic-island-hook"
        )
    }

    func testCodexSourcePrefix_stripped() {
        XCTAssertEqual(
            stripCommandPrefix("ISLAND_SOURCE=codex '/Users/foo/.codex/hooks/dynamic-island-hook'"),
            "/Users/foo/.codex/hooks/dynamic-island-hook"
        )
    }

    func testEnvPrefixWithoutQuotes() {
        XCTAssertEqual(
            stripCommandPrefix("CC_ISLAND_STOP_TIMEOUT=30 /Users/foo/.claude/hooks/dynamic-island-hook"),
            "/Users/foo/.claude/hooks/dynamic-island-hook"
        )
    }

    // MARK: - Negative matches: no env, just path

    func testLowercaseAtStart_notTreatedAsEnv() {
        // env keys must start uppercase per POSIX convention; a
        // lowercase token at the start is part of the path.
        XCTAssertEqual(
            stripCommandPrefix("/usr/local/bin/hook"),
            "/usr/local/bin/hook"
        )
    }

    func testNoEnvPrefixWhenNoEqualsSign() {
        XCTAssertEqual(
            stripCommandPrefix("just /usr/local/bin/hook"),
            "just /usr/local/bin/hook"
        )
    }

    // MARK: - Whitespace handling

    func testLeadingTrailingWhitespace_trimmed() {
        XCTAssertEqual(
            stripCommandPrefix("   '/path/hook'   "),
            "/path/hook"
        )
    }
}
