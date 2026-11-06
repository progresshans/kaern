import Foundation

/// Who made a commit and when.
public struct Signature: Sendable, Hashable {
    public var name: String
    public var email: String
    public var date: Date

    public init(name: String, email: String, date: Date) {
        self.name = name
        self.email = email
        self.date = date
    }

    /// Up to two initials for avatar circles ("Han Hyeonjin" → "HH").
    public var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        if !letters.isEmpty { return letters.joined() }
        return email.first.map { String($0).uppercased() } ?? "?"
    }
}

/// A commit as shown in the history list. Loaded in pages, so it only carries the subject line.
public struct Commit: Sendable, Hashable, Identifiable {
    /// Full object name.
    public var id: String
    public var parents: [String]
    public var author: Signature
    public var subject: String

    public init(id: String, parents: [String], author: Signature, subject: String) {
        self.id = id
        self.parents = parents
        self.author = author
        self.subject = subject
    }

    public var shortID: String { String(id.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
}

/// Everything the Commit inspector needs about one commit.
public struct CommitDetails: Sendable, Hashable {
    public var commit: Commit
    public var committer: Signature
    /// The full message, including the subject line.
    public var message: String

    public init(commit: Commit, committer: Signature, message: String) {
        self.commit = commit
        self.committer = committer
        self.message = message
    }

    /// The message without its first paragraph (the subject).
    public var body: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "\n\n") else { return "" }
        return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An entry of `git stash list`.
public struct Stash: Sendable, Hashable, Identifiable {
    public var index: Int
    public var id: String
    public var message: String
    public var date: Date

    public init(index: Int, id: String, message: String, date: Date) {
        self.index = index
        self.id = id
        self.message = message
        self.date = date
    }

    /// `stash@{n}`
    public var reference: String { "stash@{\(index)}" }
}
