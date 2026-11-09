import Foundation

/// Parses `git for-each-ref --format=<RefParser.format>`.
public enum RefParser {
    public static let format = [
        "%(refname)",
        "%(objectname)",
        "%(*objectname)",
        "%(upstream:short)",
        "%(upstream:track,nobracket)",
        "%(symref)",
        "%(HEAD)",
    ].joined(separator: "%1f")

    public static func parse(_ text: String) -> [Ref] {
        text.split(separator: "\n").compactMap { line in
            let fields = Records.fields(line)
            guard fields.count >= 7 else { return nil }
            let fullName = fields[0]
            let kind: RefKind
            if fullName.hasPrefix("refs/heads/") {
                kind = .localBranch
            } else if fullName.hasPrefix("refs/remotes/") {
                kind = .remoteBranch
            } else if fullName.hasPrefix("refs/tags/") {
                kind = .tag
            } else {
                return nil
            }
            let track = parseTrack(fields[4])
            return Ref(
                fullName: fullName,
                kind: kind,
                target: fields[2].isEmpty ? fields[1] : fields[2],
                upstream: fields[3].isEmpty ? nil : fields[3],
                ahead: track.ahead,
                behind: track.behind,
                upstreamGone: track.gone,
                isSymbolic: !fields[5].isEmpty,
                symbolicTarget: fields[5].isEmpty ? nil : fields[5],
                isHead: fields[6] == "*"
            )
        }
    }

    /// "ahead 2, behind 1" · "ahead 2" · "behind 1" · "gone" · ""
    static func parseTrack(_ text: String) -> (ahead: Int, behind: Int, gone: Bool) {
        if text == "gone" { return (0, 0, true) }
        var ahead = 0
        var behind = 0
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = count }
            if words[0] == "behind" { behind = count }
        }
        return (ahead, behind, false)
    }
}
