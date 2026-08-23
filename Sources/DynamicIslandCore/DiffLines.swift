import Foundation

/// Reading a detail block as a diff — or deciding that it is not one.
///
/// This lived inside the view that draws it, which meant the one rule here with a real edge case
/// could only be checked by looking at a screenshot. What the view keeps is colours and fonts;
/// what moved out is the part that decides *what kind of line this is*.
public enum DiffLineKind: Equatable, Sendable {
    case added
    case removed
    case plain
}

public enum DiffLines {

    /// How many lines a compact detail block shows before it stops and says how many are left.
    public static let compactLimit = 10

    /// Whether a block should be read as a diff at all.
    ///
    /// **It takes an addition, not a deletion.** A block of markdown bullets — `- one`, `- two` —
    /// is a perfectly ordinary detail, and treating a leading `- ` as authoritative would paint
    /// every one of them in delete-red as if the agent were removing them. An added line has no
    /// such collision: nothing else in these payloads starts with `+ `.
    public static func looksLikeDiff<S: StringProtocol>(_ lines: [S]) -> Bool {
        lines.contains { $0.hasPrefix("+ ") }
    }

    /// The kind of each line, in order.
    ///
    /// Classified against the block rather than line by line, because whether `- foo` is a
    /// deletion depends on whether the thing it sits in is a diff at all.
    public static func kinds(of text: String) -> [DiffLineKind] {
        let lines = split(text)
        guard looksLikeDiff(lines) else { return lines.map { _ in .plain } }
        return lines.map { line in
            if line.hasPrefix("- ") { return .removed }
            if line.hasPrefix("+ ") { return .added }
            return .plain
        }
    }

    /// What a compact block shows, and how many lines it is not showing.
    ///
    /// The count is returned rather than a formatted string: "… +3 more" is wording, and wording
    /// belongs to the view — this only has to be right about the arithmetic. `hidden` is zero
    /// when everything fits, which is the caller's cue to draw nothing rather than "+0 more".
    public static func compact(_ text: String, limit: Int = compactLimit)
        -> (lines: [Substring], hidden: Int) {
        let lines = split(text)
        guard lines.count > limit else { return (lines, 0) }
        return (Array(lines.prefix(limit)), lines.count - limit)
    }

    /// Blank lines are kept: a diff's empty context line is part of its shape, and dropping it
    /// would silently reflow what somebody is being asked to approve.
    public static func split(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
