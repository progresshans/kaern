import Foundation

/// Parses `git log -z --format=<LogParser.format>`.
public enum LogParser {
    /// Hash, parents, author name, author email, author date, subject, body. The body is last, so
    /// anything in it (even a unit separator) stays in that field.
    public static let format = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b"

    public static func parse(_ data: Data) -> [Commit] {
        Records.splitNUL(data).compactMap(parseRecord)
    }

    static func parseRecord(_ record: String) -> Commit? {
        // `git log -z` may leave a newline in front of a record.
        let trimmed = record.drop(while: { $0 == "\n" })
        let fields = Records.fields(trimmed, maxSplits: 6)
        // Six fields: output of the old format without a body.
        guard fields.count >= 6, fields[0].count >= 7 else { return nil }
        return Commit(
            id: fields[0],
            parents: fields[1].split(separator: " ").map(String.init),
            author: Signature(name: fields[2], email: fields[3], date: Records.date(fromUnix: fields[4])),
            subject: fields[5],
            bodyPreview: fields.count > 6 ? Commit.preview(ofBody: fields[6]) : ""
        )
    }
}

/// Parses `git show -s --format=<CommitDetailsParser.format>`.
public enum CommitDetailsParser {
    public static let format = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%B"

    public static func parse(_ text: String) -> CommitDetails? {
        let fields = Records.fields(text, maxSplits: 8)
        guard fields.count == 9 else { return nil }
        let message = fields[8].trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let commit = Commit(
            id: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
            parents: fields[1].split(separator: " ").map(String.init),
            author: Signature(name: fields[2], email: fields[3], date: Records.date(fromUnix: fields[4])),
            subject: subject
        )
        let committer = Signature(name: fields[5], email: fields[6], date: Records.date(fromUnix: fields[7]))
        return CommitDetails(commit: commit, committer: committer, message: message)
    }
}

/// Parses `git stash list --format=<StashParser.format>`.
public enum StashParser {
    public static let format = "%gd%x1f%H%x1f%gs%x1f%at"

    public static func parse(_ text: String) -> [Stash] {
        text.split(separator: "\n").compactMap { line in
            let fields = Records.fields(line, maxSplits: 3)
            guard fields.count == 4 else { return nil }
            // stash@{3}
            let reference = fields[0]
            guard let open = reference.firstIndex(of: "{"), let close = reference.lastIndex(of: "}"),
                  let index = Int(reference[reference.index(after: open)..<close]) else { return nil }
            return Stash(index: index, id: fields[1], message: fields[2], date: Records.date(fromUnix: fields[3]))
        }
    }
}
