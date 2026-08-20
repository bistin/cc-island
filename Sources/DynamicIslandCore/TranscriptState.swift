import Foundation

/// What a Claude Code session is doing, read out of the transcript it is already writing.
///
/// Every event the island shows today arrives because a hook pushed it. That works, and it has a
/// hole shaped exactly like the hook: a session started before the hook was installed is invisible,
/// and between two pushes the island has nothing to say — it is showing the last thing that
/// happened, not what is happening. The transcript is the other half. Claude Code writes
/// `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` for its own reasons, on every session,
/// whether or not anything is installed, and reading it costs one file read.
///
/// **What the transcript can answer, and what it cannot, was measured rather than assumed.**
/// Both halves matter, and the second one is the surprise:
///
/// - **`working` and `idle` are solid.** A turn ends with a `system` entry whose `subtype` is
///   `turn_duration`, and the file keeps growing during a turn — one append per tool as it
///   finishes — so "the newest significant entry is not a turn ending" is a real answer about now.
/// - **`waiting` is not in here at all**, and no amount of parsing will put it there. Claude Code
///   writes an assistant `tool_use` and its `tool_result` *together, after the tool returns*. The
///   pending window is never on disk. Measured three times from inside a live session: with a tool
///   call demonstrably in flight, the transcript reported zero outstanding `tool_use` entries and
///   its newest entry predated the call by 26, 32 and 54 seconds. So a permission prompt sitting
///   unanswered, and an `AskUserQuestion` waiting on a person, look from here exactly like a
///   session that is quietly busy — because on disk, at that moment, they *are* the same bytes.
///
/// Which is why there is no `waiting` case below. Inventing one out of "a tool has been
/// outstanding a while" would be a confident wrong answer about somebody's work, and the island
/// already has a source that knows for certain: the `PermissionRequest` hook, which fires exactly
/// when a person is being asked. This file is not a replacement for that and does not try to be.
public enum SessionActivity: Equatable {
    /// The session is mid-turn. Something is running, or Claude is generating.
    case working
    /// The turn ended. Nothing is running; whether anybody intends to type again is not knowable
    /// from here, and deliberately not guessed at.
    case idle
    /// The transcript could not be read, held nothing worth reading, or has gone quiet for long
    /// enough that a `working` answer would be a claim rather than a reading.
    ///
    /// **Not folded into `idle`**, which is the one rule here worth stating twice. A session whose
    /// transcript cannot be read is not the same as one that finished, and drawing it as finished
    /// is a confident wrong answer about the state of somebody's work.
    case unknown
}

/// A reading, with the evidence it was made from — so a caller can show *why* rather than only
/// what, and so a wrong answer can be traced to the line that caused it.
public struct TranscriptReading: Equatable {
    public let activity: SessionActivity
    /// The newest timestamp anywhere in the file, bookkeeping entries included. This is a question
    /// about whether the file is alive, so every entry that carries a clock counts.
    public let lastActivityAt: Date?
    /// The `type` of the entry the verdict came from — `"assistant"`, `"system"`, `"user"` — or
    /// nil when there was nothing significant to read.
    public let decidedBy: String?

    public init(activity: SessionActivity, lastActivityAt: Date? = nil, decidedBy: String? = nil) {
        self.activity = activity
        self.lastActivityAt = lastActivityAt
        self.decidedBy = decidedBy
    }
}

public enum TranscriptState {

    /// How long a session may go without writing anything before `working` decays to `unknown`.
    ///
    /// It decays to `unknown` rather than to `idle` on purpose: a session that stopped writing
    /// mid-turn was killed, or its machine slept, or it is on a tool that takes a very long time.
    /// Those are different from a finished turn, and only a finished turn writes `turn_duration`.
    ///
    /// Five minutes because appends happen once per completed tool, and a single `Bash` step is
    /// allowed to run for ten. Shorter would call a slow build a dead session.
    public static let defaultStaleAfter: TimeInterval = 300

    /// Entry types that say nothing about whether work is happening.
    ///
    /// Claude Code writes a good deal of housekeeping into the same file — the session title it
    /// generated, the last prompt for resume, snapshots of the files it has touched. Every one of
    /// them appears *between* the entries that matter, so a reader that took "the last line" as
    /// the answer would be reading a file-history snapshot about a third of the time.
    static let bookkeepingTypes: Set<String> = [
        "mode", "atis-latch", "ai-title", "last-prompt", "pr-link",
        "file-history-snapshot", "file-history-delta", "queue-operation", "attachment",
    ]

    /// How much of the tail to read before parsing anything.
    ///
    /// **Reading the whole file is not affordable and was measured rather than guessed.** These
    /// grow without bound — 44 MB and 31 MB on the development machine — and parsing every line
    /// of one cost 281 ms and 518 ms respectively. Nothing in the verdict needs any of that: a
    /// turn ending, an interrupted turn, the newest entry, are all at the end.
    ///
    /// 64 KB covers a few hundred ordinary entries. When it does not — a single record can be a
    /// megabyte, so a window can land entirely inside one and contain no complete line at all —
    /// ``read(fileAt:now:staleAfter:tailBytes:)`` widens it rather than answering from nothing.
    public static let defaultTailBytes = 64_000

    /// Where widening stops. Past this the answer is `unknown`, which is the honest one: a file
    /// whose last four megabytes say nothing about what the session is doing has not told us.
    public static let maxTailBytes = 4_194_304

    /// The directory Claude Code keeps a project's sessions in.
    ///
    /// **Every character that is not an ASCII letter or digit becomes a dash — not just the
    /// separators.** Getting this wrong fails silently in the worst way: a transcript that cannot
    /// be found is an ordinary state, so a wrong slug does not raise anything, it just makes the
    /// session look like one Claude Code never wrote about.
    ///
    /// Confirmed against a real directory rather than taken on trust. `~/Desktop/毒` appears on
    /// disk as `-Users-bistin-Desktop--`: the slash becomes one dash and the ideograph becomes
    /// another. Replacing only `/` would have produced `-Users-bistin-Desktop-毒`, which is not
    /// there, so that session's transcript would never have been located.
    ///
    /// Counted in UTF-16 code units, which is what makes that example come out at one dash and an
    /// emoji come out at two.
    ///
    /// **The map is many-to-one, so use it only forwards.** `-Users-me-code-app-web` is both
    /// `app/web` and `app-web` and nothing in the name says which; never read a path back out of
    /// one.
    public static func projectSlug(for cwd: String) -> String {
        var out = ""
        out.reserveCapacity(cwd.utf16.count)
        for unit in cwd.utf16 {
            let isASCIIAlphanumeric = (unit >= 48 && unit <= 57)      // 0-9
                || (unit >= 65 && unit <= 90)                          // A-Z
                || (unit >= 97 && unit <= 122)                         // a-z
            out.append(isASCIIAlphanumeric ? Character(UnicodeScalar(UInt8(unit))) : "-")
        }
        return out
    }

    /// The transcript for one session, given the two things every hook payload already carries.
    ///
    /// cc-island is better placed here than a tool that has to guess: the hook reports `cwd` and
    /// `session_id`, and the file is named for the session, so nothing has to be matched by title
    /// or by modification time.
    ///
    /// **nil for a session id that is not a plain filename**, which is a boundary rather than
    /// tidiness. `cwd` goes through ``projectSlug(for:)`` and comes out incapable of holding a
    /// separator; the session id does not, and it arrives in an HTTP payload like everything else
    /// the hook sends. `appendingPathComponent` treats a `/` in it as structure — `"n/a"` yields
    /// `…/projects/<slug>/n/a.jsonl`, a different directory — so `..` would climb out of the
    /// tree entirely. Rejected rather than slugged: mangling a session id would look up the wrong
    /// file and say nothing about it, while nil is an answer the caller can see.
    public static func transcriptURL(cwd: String, sessionID: String, home: URL? = nil) -> URL? {
        guard isPlainFilename(sessionID) else { return nil }
        let base = home ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(projectSlug(for: cwd), isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
    }

    /// A single path component and nothing else: non-empty, no separator, no null, and not a
    /// relative-path token. Deliberately not a UUID check — Claude Code names the file after the
    /// session id and has never promised what that looks like.
    static func isPlainFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard name != ".", name != ".." else { return false }
        return !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    /// Read a verdict from a transcript on disk, touching only as much of the tail as it takes.
    ///
    /// Starts at `tailBytes` and widens eightfold until something significant is found, the whole
    /// file has been read, or ``maxTailBytes`` is reached. Widening is what makes a small default
    /// safe: a window that lands inside one enormous record, or in a run of housekeeping entries,
    /// asks for more instead of reporting `unknown` about a file it barely looked at.
    ///
    /// A missing or unreadable file is `unknown` — not an error and not `idle`.
    public static func read(
        fileAt url: URL,
        now: Date,
        staleAfter: TimeInterval = defaultStaleAfter,
        tailBytes: Int = defaultTailBytes
    ) -> TranscriptReading {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        guard let size, size > 0 else { return TranscriptReading(activity: .unknown) }

        var window = max(1, tailBytes)
        while true {
            guard let lines = tailLines(of: url, bytes: window) else {
                return TranscriptReading(activity: .unknown)
            }
            let reading = read(lines: lines, now: now, staleAfter: staleAfter)
            // `decidedBy` is nil exactly when nothing significant was in the window.
            if reading.decidedBy != nil || window >= size || window >= maxTailBytes {
                return reading
            }
            window = min(window * 8, min(size, maxTailBytes))
        }
    }

    /// The last `bytes` of a file, as lines, with the first one dropped when the read started
    /// mid-file — cutting at a byte offset lands in the middle of a line, and half a record is
    /// not a record. That also disposes of any partial UTF-8 sequence at the boundary.
    static func tailLines(of url: URL, bytes: Int) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0 {
            // No newline anywhere means the window landed entirely inside one record — records
            // reach a megabyte — so it holds no complete line at all. Empty, rather than half a
            // line: the caller widens on that, and a half-line is not evidence of anything.
            guard let newline = text.firstIndex(of: "\n") else { return [] }
            text = String(text[text.index(after: newline)...])
        }
        return text.components(separatedBy: "\n")
    }

    /// Read a verdict out of the transcript's lines.
    ///
    /// Takes lines rather than a path so the whole of the decision is testable without a
    /// filesystem, which is the same split `HTTPParser` and `ScreenResolver` already use.
    ///
    /// - Parameters:
    ///   - lines: the file, split on newlines. Unparseable lines are skipped rather than fatal —
    ///     a transcript being appended to can be caught mid-line, and half a line is a timing
    ///     accident, not a corrupt file.
    ///   - now: passed in rather than read, so staleness is testable.
    ///   - staleAfter: see ``defaultStaleAfter``.
    public static func read(
        lines: [String],
        now: Date,
        staleAfter: TimeInterval = defaultStaleAfter
    ) -> TranscriptReading {
        var newestTimestamp: Date?
        var verdict: SessionActivity?
        var decidedBy: String?

        // Forward, not backward: the newest timestamp needs every entry anyway, and one pass that
        // remembers the last significant row costs the same as two passes that do not.
        for line in lines {
            guard let row = parse(line) else { continue }
            if let at = timestamp(in: row) {
                if newestTimestamp == nil || at > newestTimestamp! { newestTimestamp = at }
            }
            let type = row["type"] as? String ?? ""
            guard !type.isEmpty, !bookkeepingTypes.contains(type) else { continue }
            guard let activity = activity(ofSignificant: row, type: type) else { continue }
            verdict = activity
            decidedBy = type
        }

        guard let verdict else {
            return TranscriptReading(activity: .unknown, lastActivityAt: newestTimestamp)
        }

        // A live-looking verdict that nothing has backed up in a long time is not a reading any
        // more. Only `working` decays: `idle` was written down by Claude Code itself and does not
        // get less true with age.
        if verdict == .working, let at = newestTimestamp, now.timeIntervalSince(at) > staleAfter {
            return TranscriptReading(activity: .unknown, lastActivityAt: at, decidedBy: decidedBy)
        }
        return TranscriptReading(activity: verdict, lastActivityAt: newestTimestamp, decidedBy: decidedBy)
    }

    // MARK: - One entry

    /// nil when the entry is significant in principle but says nothing either way, so the previous
    /// verdict stands rather than being overwritten with a guess.
    private static func activity(ofSignificant row: [String: Any], type: String) -> SessionActivity? {
        switch type {
        case "system":
            // The turn ending, written by Claude Code with the duration it took. The cleanest
            // marker in the file, and the only one that means "nothing is running" outright.
            return row["subtype"] as? String == "turn_duration" ? .idle : nil

        case "user":
            // An interrupted turn is over in the only sense that matters here: the person took the
            // keyboard back. Claude Code does not write `turn_duration` for one, so without this
            // an interrupted session would read as working until it went stale.
            if row["interruptedMessageId"] != nil, !(row["interruptedMessageId"] is NSNull) {
                return .idle
            }
            // Everything else from the user — a typed prompt, a tool result coming back — means
            // the turn is live and Claude has the ball.
            return .working

        case "assistant":
            // `end_turn` is the same fact as `turn_duration`, one entry earlier. Both are read
            // because the pair is written separately and a file caught between them would
            // otherwise report the finished turn as still running.
            let message = row["message"] as? [String: Any]
            return message?["stop_reason"] as? String == "end_turn" ? .idle : .working

        default:
            return nil
        }
    }

    private static func parse(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func timestamp(in row: [String: Any]) -> Date? {
        guard let raw = row["timestamp"] as? String else { return nil }
        return date(fromISO8601: raw)
    }

    /// Both shapes, because the file carries fractional seconds and nothing promises it always
    /// will — `ISO8601DateFormatter` returns nil rather than degrading when the option and the
    /// string disagree, so one formatter alone would silently stop reading clocks.
    static func date(fromISO8601 raw: String) -> Date? {
        if let d = fractional.date(from: raw) { return d }
        return plain.date(from: raw)
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
