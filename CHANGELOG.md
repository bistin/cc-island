# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.0] - 2026-04-24

### Added
- **Multi-display support** — the Island follows the cursor across screens.
  Triggers: `/event` POST (instant), 200 ms cursor dwell on a new screen,
  or `didChangeScreenParametersNotification`. Relocation is a
  fade-out → re-derive notch metrics → `setFrame` → fade-in (~0.35 s
  total); mid-event state (permission dialogs, progress, reminders)
  survives the move. Non-notch screens use the capsule layout. New
  `ScreenFollower` (50 ms poll + 200 ms dwell), `IslandPanel.relocate(to:animated:)`,
  and `NSScreen+Display` helpers. Single-screen setups are unaffected.
  ([#12](https://github.com/bistin/cc-island/issues/12) / [#13](https://github.com/bistin/cc-island/pull/13), thanks @xero7689)
- **`DynamicIslandCore` SPM library target** — pure-logic module
  (Foundation-only) housing `ScreenResolver` and `HTTPParser` so the
  app's non-AppKit pieces are unit-testable. Mirrors the existing
  `IslandHookCore` pattern.
- **20 new unit tests** — 5 × `ScreenResolverTests` (point-in-rect
  lookup) + 15 × `HTTPParserTests` (split reads, framing errors,
  duplicate / conflicting `Content-Length`, `Transfer-Encoding`
  rejection, oversize). Total test count: **88**.

### Fixed
- **HTTP requests read across multiple TCP chunks.** `LocalServer`
  previously called `connection.receive()` once per connection and
  treated the bytes as one complete request. On loopback, `URLSession`
  (used by the Swift `island-hook` binary) routinely delivers headers
  and body in separate chunks — so the server returned 400 `missing_body`
  and hook events silently dropped, at measured rates around 80% of
  POSTs. `handleConnection` now loops until the full request is
  buffered; parsing is extracted to `DynamicIslandCore.HTTPParser`.
  Users should see many fewer "the notch didn't appear" moments.
  ([#14](https://github.com/bistin/cc-island/issues/14) / [#15](https://github.com/bistin/cc-island/pull/15), thanks @xero7689)
- Latent bug in `IslandPanel.updateSize(to:animated:)` — hard-coded to
  `NSScreen.main`, which would misplace the panel on a secondary display
  after a relocate. Now uses the panel's current screen.

### Changed
- HTTP framing hardened per RFC 7230 §3.3: duplicate / conflicting
  `Content-Length` → 400 `malformed_request` (was: silent overwrite);
  `Transfer-Encoding` (chunked decoder not implemented) → 400
  `malformed_request` (was: accepted with ambiguous framing); declared
  size over 1 MiB → 413 `payload_too_large` fail-fast (was: buffered
  then cancelled).
- `Info.plist` `CFBundleVersion` / `CFBundleShortVersionString` bumped
  from `1.0.0` to `1.6.0`. Previous releases shipped with stale version
  strings; now synced with the tag.

## [1.5.0] - 2026-04-22

### Added
- **Hook is now a Swift binary** (~109KB Foundation-only Mach-O), shipped
  in the .app bundle and deployed to `~/.claude/hooks/dynamic-island-hook`
  / `~/.copilot/hooks/dynamic-island-hook`. **No more `jq` dependency.**
- `IslandHookCore` SPM library — pure logic (parsing, source detection,
  payload builders, formatting helpers) covered by **68 unit tests**.
  Run with `swift test`.
- **Stop event shows the actual question** Claude is asking instead of
  generic "Your turn". `extractLastQuestion` splits on sentence terminators
  (English `. ! ?`, fullwidth `。 ！ ？`, newlines) and takes the trailing
  sentence; the full message is also placed in `detail` for the expanded view.
- **Menu bar icon** with a horizontal-pill template (Dynamic Island
  silhouette). Menu items: version, Reinstall Claude Code Hooks, Quit
  Dynamic Island. No more `pkill DynamicIsland` from terminal.

### Changed
- `HookInstaller` deploys the binary instead of the shell script. On
  first launch it cleans up any legacy `.sh` deployment from the old path.
- Hook content drift detection: `currentlyInSync` byte-compares the
  deployed binary against the bundled source, so upgrading the .app
  triggers a redeploy automatically.
- README and CLAUDE.md updated end-to-end for the new binary, no-jq
  reality, and the IslandHookCore architecture.

### Fixed
- Idle island used to swallow clicks behind the camera notch — menu-bar
  items there are reachable again. Panel now toggles `ignoresMouseEvents`
  based on state.

### Removed
- `hooks/island-hook.sh`, `hooks/claude-hook.sh`, `hooks/copilot-hooks.json`
  — superseded by the binary; the Copilot example was using an outdated
  schema anyway.

## [1.4.3] - 2026-04-22

### Added
- **Menu bar icon** — `NSStatusItem` with a horizontal-pill template icon
  (the Dynamic Island silhouette in compact form). Click target uses the
  full 22×22 canvas so it hits like any other menu-bar item.
- Menu items: version label, **Reinstall Claude Code Hooks**, **Quit
  Dynamic Island** — no more `pkill DynamicIsland` from terminal.

### Fixed
- The panel spans `earWidth*2 + notchWidth` (~465pt) and used to swallow
  every click in that strip even when no event was showing, making
  menu-bar items behind the camera notch unreachable. Now toggles
  `ignoresMouseEvents` based on state — clicks pass through when idle.

## [1.4.2] - 2026-04-22

### Fixed
- Source detection misclassified Claude Code events as Copilot. `bash`'s
  `case "$CC_EVENT" in [a-z]*)` matches uppercase letters too in
  `en_US.UTF-8` because the locale interleaves cases (P falls inside
  `[a-z]`). Switched to `[[:upper:]]` POSIX class. Without this fix,
  Claude events showed whatever the project-name-hash palette landed on
  instead of warm orange.
- `currentlyInSync` now byte-compares the deployed script against the
  bundled source. Previously, after upgrading the .app, the stale copy
  at `~/.claude/hooks/dynamic-island-hook` would keep running and
  silently drop new fields like `source`. Drift now triggers redeploy
  on next launch or `--install-hooks` invocation.

## [1.4.1] - 2026-04-22

### Added
- **Source-aware color** — a vertical color stripe down each ear's outer edge
  signals which AI sent the event: warm orange for Claude Code, GitHub violet
  for Copilot, OpenAI green for Codex. Action / reminder pulse stroke and
  shadow follow the same color, so a permission request from Claude glows
  orange instead of generic blue.
- Hook script auto-detects source by `hook_event_name` casing
  (PascalCase → Claude, camelCase → Copilot) with a fallback to the legacy
  `toolName`-at-root sniff. `ISLAND_SOURCE` env var lets Codex hooks opt in.
- `IslandEvent.source` field — also accepted in HTTP `/event` payloads.

### Changed
- `projectColor` prefers the source color when known; the previous
  project-name hash palette is still used as a fallback for events without
  a source field, so legacy callers stay visually distinct.

## [1.4.0] - 2026-04-22

### Added
- **Auto hook installation** — first launch shows an NSAlert (Install / Skip / Never) and
  configures Claude Code hooks automatically. Choice persists in UserDefaults; subsequent
  launches silently sync if the deployed script or settings drift out of date.
- **CLI flags** for scripted setup:
  - `--install-hooks` / `--uninstall-hooks` (Claude Code, writes `~/.claude/settings.json`)
  - `--install-copilot-hooks [path]` / `--uninstall-copilot-hooks [path]`
    (Copilot, writes `{path}/.github/hooks/hooks.json`, defaults to current directory)
  - `--help` for usage
- `HookInstaller.swift` — manages script deployment and settings.json manipulation for
  both Claude Code and Copilot. Detects existing entries by command-path markers so
  other tools' hooks (e.g. gemini-bridge) are preserved.
- HTTP server now returns 400 on invalid `/event` payloads instead of silent 200
  (thanks @xero7689, [#2](https://github.com/bistin/cc-island/pull/2)).

### Changed
- Hooks now deploy to `~/.claude/hooks/dynamic-island-hook` (stable path independent
  of the .app location). Moving the .app no longer breaks the registration.
- Copilot hooks use the official schema per
  [docs.github.com](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-hooks):
  per-repo `.github/hooks/hooks.json`, top-level `version: 1`, camelCase event names
  (`preToolUse`, `postToolUse`, `userPromptSubmitted`, `sessionStart`, `sessionEnd`,
  `errorOccurred`), `bash` / `timeoutSec` fields.

### Safety
- Installer refuses to overwrite `~/.claude/settings.json` if existing JSON is unparseable.
- `currentlyInSync` check verifies the deployed script file exists, not just the settings
  entries — so a user-deleted script triggers redeploy on next launch.

## [1.3.0] - 2026-04-21

### Added
- Six previously-missing Claude Code hook events:
  - `PostToolUseFailure` — replaces fragile grep-based failure detection
  - `PermissionDenied` — auto-mode silent denials surface as warnings
  - `StopFailure` — rate limit / auth / billing errors are now visible
  - `SessionEnd` — clears thinking state on session close
  - `PreCompact` / `PostCompact` — context compaction progress
- **FIFO context correlation** — `PreToolUse` caches its full payload to
  `/tmp/di_pretool_${PROJECT}.json`; the next `PermissionRequest` reads it to
  show a colored diff (Edit), content preview (Write), or fallback command (Bash).

### Fixed
- `jq` error when `.error` field is a string in `PostToolUseFailure` payload.

## [1.0.0] - 2026-04-02

Initial release. See repo history for details.

[1.5.0]: https://github.com/bistin/cc-island/compare/v1.4.3...v1.5.0
[1.4.3]: https://github.com/bistin/cc-island/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/bistin/cc-island/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/bistin/cc-island/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/bistin/cc-island/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/bistin/cc-island/compare/v1.0.0...v1.3.0
[1.0.0]: https://github.com/bistin/cc-island/releases/tag/v1.0.0
