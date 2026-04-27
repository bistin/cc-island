import XCTest
@testable import IslandHookCore

final class PreToolCacheTests: XCTestCase {

    // MARK: - preToolCacheKey

    func testKey_prefersSessionID() {
        let plan = makePlan(sessionID: "abc-123", agentId: "ag-1", project: "demo")
        XCTAssertEqual(preToolCacheKey(plan: plan), "abc-123")
    }

    func testKey_fallsBackToAgentAndProjectWhenNoSessionID() {
        let plan = makePlan(sessionID: nil, agentId: "ag-1", project: "demo")
        XCTAssertEqual(preToolCacheKey(plan: plan), "agent-ag-1-demo")
    }

    func testKey_fallsBackToProjectWhenNoSessionOrAgent() {
        let plan = makePlan(sessionID: nil, agentId: nil, project: "demo")
        XCTAssertEqual(preToolCacheKey(plan: plan), "demo")
    }

    func testKey_defaultWhenNothing() {
        let plan = makePlan(sessionID: nil, agentId: nil, project: "")
        XCTAssertEqual(preToolCacheKey(plan: plan), "default")
    }

    func testKey_emptySessionIDFallsThrough() {
        // An empty session_id is treated as "no session" — fall through
        // to agent-based or project-based key.
        let plan = makePlan(sessionID: "", agentId: nil, project: "demo")
        XCTAssertEqual(preToolCacheKey(plan: plan), "demo")
    }

    func testKey_emptyAgentIdFallsThrough() {
        let plan = makePlan(sessionID: nil, agentId: "", project: "demo")
        XCTAssertEqual(preToolCacheKey(plan: plan), "demo")
    }

    func testKey_sanitisesUnsafeProjectName() {
        // Path separators in project name (e.g. someone passing the
        // full cwd through) shouldn't escape the pretool/ directory.
        let plan = makePlan(sessionID: nil, agentId: nil, project: "foo/bar")
        XCTAssertEqual(preToolCacheKey(plan: plan), "foo_bar")
    }

    func testKey_sanitisesAgentBranchInputs() {
        let plan = makePlan(sessionID: nil, agentId: "ag/1", project: "demo space")
        XCTAssertEqual(preToolCacheKey(plan: plan), "agent-ag_1-demo_space")
    }

    func testKey_sanitisesSessionIDPath() {
        let plan = makePlan(sessionID: "sess/with/slash", agentId: nil, project: "demo")
        XCTAssertEqual(preToolCacheKey(plan: plan), "sess_with_slash")
    }

    // MARK: - sanitiseCacheKey

    func testSanitise_passthroughForSafeKey() {
        XCTAssertEqual(sanitiseCacheKey("abc-123_demo"), "abc-123_demo")
    }

    func testSanitise_replacesPathSeparatorsAndMetas() {
        XCTAssertEqual(
            sanitiseCacheKey("a/b\\c:d?e<f>g|h*i\"j"),
            "a_b_c_d_e_f_g_h_i_j"
        )
    }

    func testSanitise_replacesWhitespace() {
        XCTAssertEqual(sanitiseCacheKey("foo bar\tbaz"), "foo_bar_baz")
    }

    func testSanitise_emptyBecomesDefault() {
        XCTAssertEqual(sanitiseCacheKey(""), "default")
    }

    // MARK: - preToolCacheURL

    func testURL_underProvidedCachesDirectory() {
        let temp = URL(fileURLWithPath: "/tmp/test-cache-base")
        let url = preToolCacheURL(key: "session-xyz", cachesDirectory: temp)
        XCTAssertEqual(
            url.path,
            "/tmp/test-cache-base/cc-island/pretool/session-xyz.json"
        )
    }

    func testURL_defaultRoutesUnderCcIslandPretool() {
        // Default uses `.cachesDirectory` which on macOS is
        // `~/Library/Caches`. We only assert the suffix shape so
        // sandboxed / non-sandboxed builds both pass.
        let url = preToolCacheURL(key: "k")
        XCTAssertTrue(
            url.path.hasSuffix("/cc-island/pretool/k.json"),
            "unexpected path: \(url.path)"
        )
    }

    // MARK: - Helpers

    private func makePlan(
        sessionID: String?,
        agentId: String?,
        project: String
    ) -> HookPlan {
        HookPlan(
            payload: [:], source: "claude", event: "PreToolUse", tool: "Edit",
            cwd: "/tmp", project: project, displayProject: project,
            agentId: agentId, agentType: agentId == nil ? nil : "general",
            sessionID: sessionID,
            toolInput: [:], copilotToolArgs: [:],
            cpError: nil
        )
    }
}
