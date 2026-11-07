import Foundation

/// What the history does with commits bots make (View › Bot Commits).
public enum BotCommits: String, Sendable, CaseIterable {
    /// Runs of three or more by one bot become one row (the default).
    case collapse
    /// Every commit, as git lists them.
    case show
    /// Bot commits leave the graph; lines run through to the commits under them.
    case hide
}

/// Commits one bot made one after another, shown as one row: "13 image updates by
/// deployer[bot]" (ScreenBigRepo).
public struct BotRun: Sendable, Hashable, Identifiable {
    /// Newest first.
    public var commits: [Commit]
    public var bot: String

    public var id: String { commits[0].id }
    public var newest: Date { commits[0].author.date }
    public var oldest: Date { commits[commits.count - 1].author.date }
    public var count: Int { commits.count }

    /// "13 updates by deployer[bot]", "6 dependency updates by renovate[bot]".
    public var title: String {
        let subjects = commits.map { $0.subject.lowercased() }
        let dependency = subjects.allSatisfy { subject in
            subject.contains("deps") || subject.contains("dependency") || subject.contains("dependencies") || subject.hasPrefix("bump ")
        }
        let updates = subjects.filter { $0.contains("update") || $0.contains("bump") || $0.contains("upgrade") }.count * 2 >= subjects.count
        let noun = dependency ? "dependency updates" : updates ? "updates" : "commits"
        return "\(count) \(noun) by \(bot)"
    }

    /// What the bot updated, from the subjects ("orders-api · orders-web · powerlens-feed").
    public var detail: String {
        var names: [String] = []
        for commit in commits {
            guard let name = Self.subjectName(commit.subject), !names.contains(name) else { continue }
            names.append(name)
            if names.count == 4 { break }
        }
        if names.isEmpty { return commits.prefix(2).map(\.subject).joined(separator: " · ") }
        return names.joined(separator: " · ")
    }

    /// "build: automatic update of orders-api to 1.42.3" → "orders-api"; "Bump argocd from 2.9 to
    /// 2.10" → "argocd"; "chore(deps): update helm release loki to v5" → "loki".
    static func subjectName(_ subject: String) -> String? {
        let pattern = #"(?i)\b(?:update|updates|updated|bump|bumps|bumped|upgrade|upgrades|upgraded)\s+(?:of\s+)?(?:the\s+)?(?:dependency\s+|module\s+|helm\s+release\s+|image\s+|docker\s+tag\s+|package\s+)?([A-Za-z0-9@][A-Za-z0-9@/._-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
              let range = Range(match.range(at: 1), in: subject) else { return nil }
        let name = String(subject[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".:,"))
        let skip: Set<String> = ["to", "from", "all", "dependencies", "dependency", "deps", "the", "and"]
        return skip.contains(name.lowercased()) ? nil : name
    }
}

/// The history as the graph shows it: a folded run is one commit that has the run's newest id and
/// the oldest one's parents, so lanes run through it.
public struct FoldedHistory: Sendable {
    public var commits: [Commit]
    /// Folded runs by the id of the row that stands for them.
    public var runs: [String: BotRun]
    /// Commits that are inside a folded run (not shown), by id → the run's id.
    public var insideRun: [String: String]
    /// How many bot commits the runs hold.
    public var foldedCount: Int
    /// How many bot commits Hide left out.
    public var hiddenCount: Int
    /// The loaded commits include ones by bots.
    public var hasBotCommits: Bool

    public init(commits: [Commit], runs: [String: BotRun] = [:], insideRun: [String: String] = [:], foldedCount: Int = 0,
                hiddenCount: Int = 0, hasBotCommits: Bool = false) {
        self.commits = commits
        self.runs = runs
        self.insideRun = insideRun
        self.foldedCount = foldedCount
        self.hiddenCount = hiddenCount
        self.hasBotCommits = hasBotCommits
    }
}

public enum BotFolding {
    /// Bots GitHub and GitLab put "[bot]" on; a few others go by name.
    public static func isBot(_ author: Signature) -> Bool {
        let name = author.name.lowercased()
        if name.hasSuffix("[bot]") || author.email.lowercased().contains("[bot]@") { return true }
        return ["dependabot", "renovate", "renovate-bot", "github-actions", "gitlab-bot", "semantic-release-bot"].contains(name)
    }

    /// Folds runs of at least `minimumRun` commits one bot made along a first-parent line, or with
    /// `.hide` leaves bot commits out. Commits in `keep` (refs, HEAD) always show, and runs whose
    /// id is in `expanded` stay open. A commit another branch grew from ends a run, so no line
    /// loses its end.
    public static func fold(_ commits: [Commit], mode: BotCommits, keep: Set<String>, expanded: Set<String> = [],
                            minimumRun: Int = 3) -> FoldedHistory {
        let hasBots = commits.contains { isBot($0.author) }
        guard hasBots, mode != .show else { return FoldedHistory(commits: commits, hasBotCommits: hasBots) }
        var byID: [String: Commit] = [:]
        var children: [String: Int] = [:]
        for commit in commits {
            byID[commit.id] = commit
            for parent in commit.parents { children[parent, default: 0] += 1 }
        }
        func foldable(_ commit: Commit) -> Bool {
            commit.parents.count == 1 && isBot(commit.author) && !keep.contains(commit.id)
        }

        if mode == .hide {
            // Each left-out commit hands its children to its parent.
            var redirect: [String: String] = [:]
            var hidden = 0
            for commit in commits where foldable(commit) {
                redirect[commit.id] = commit.parents[0]
                hidden += 1
            }
            func resolve(_ id: String) -> String {
                var current = id
                var steps = 0
                while let next = redirect[current], steps < 100_000 {
                    current = next
                    steps += 1
                }
                return current
            }
            var shown: [Commit] = []
            for var commit in commits where redirect[commit.id] == nil {
                var parents: [String] = []
                for parent in commit.parents.map(resolve) where !parents.contains(parent) { parents.append(parent) }
                commit.parents = parents
                shown.append(commit)
            }
            return FoldedHistory(commits: shown, hiddenCount: hidden, hasBotCommits: true)
        }

        var consumed = Set<String>()
        /// Members of runs that are open: shown one by one, never folded again.
        var open = Set<String>()
        var runs: [String: BotRun] = [:]
        var inside: [String: String] = [:]
        var folded = 0
        var result: [Commit] = []
        result.reserveCapacity(commits.count)
        for commit in commits {
            if consumed.contains(commit.id) { continue }
            guard foldable(commit), !open.contains(commit.id) else {
                result.append(commit)
                continue
            }
            // Follow the first parent while the same bot made it and nothing else grew from it.
            var chain = [commit]
            var current = commit
            while let parent = byID[current.parents[0]], foldable(parent), parent.author.name == commit.author.name,
                  children[parent.id] == 1, !consumed.contains(parent.id) {
                chain.append(parent)
                current = parent
            }
            guard chain.count >= minimumRun, !expanded.contains(commit.id) else {
                if expanded.contains(commit.id) { open.formUnion(chain.map(\.id)) }
                result.append(commit)
                continue
            }
            let run = BotRun(commits: chain, bot: commit.author.name)
            var row = commit
            row.parents = chain[chain.count - 1].parents
            row.subject = run.title
            row.bodyPreview = run.detail
            result.append(row)
            runs[commit.id] = run
            for member in chain.dropFirst() {
                consumed.insert(member.id)
                inside[member.id] = commit.id
            }
            folded += chain.count
        }
        return FoldedHistory(commits: result, runs: runs, insideRun: inside, foldedCount: folded, hasBotCommits: true)
    }
}
