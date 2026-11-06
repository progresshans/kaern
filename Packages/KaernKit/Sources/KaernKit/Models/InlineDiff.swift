import Foundation

/// Which words changed inside a modified line, so the diff can mark them on top of the line's
/// color. Lines are paired the way they're shown side by side: the n-th deleted line of a block
/// with the n-th added line that follows it.
public enum InlineDiff {
    /// Changed character ranges (offsets in `Character`s) of the paired lines of `lines`, by line
    /// ID. Lines that have too little in common to be "the same line, edited" are left out.
    public static func highlights(for lines: [(id: Int, kind: DiffLine.Kind, text: String)]) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        var deletions: [(id: Int, text: String)] = []
        var additions: [(id: Int, text: String)] = []
        func flush() {
            if deletions.count * additions.count <= 64 {
                // Each deleted line with the most alike added line after the previous match, so
                // an inserted line doesn't throw the pairs below it off.
                var start = 0
                for old in deletions where start < additions.count {
                    var best: (index: Int, match: Match)?
                    for index in start ..< additions.count {
                        if let match = compare(old: old.text, new: additions[index].text), match.common > (best?.match.common ?? 0) {
                            best = (index, match)
                        }
                    }
                    guard let best else { continue }
                    result[old.id] = best.match.old
                    result[additions[best.index].id] = best.match.new
                    start = best.index + 1
                }
            } else {
                for (old, new) in zip(deletions, additions) {
                    if let match = compare(old: old.text, new: new.text) {
                        result[old.id] = match.old
                        result[new.id] = match.new
                    }
                }
            }
            deletions.removeAll()
            additions.removeAll()
        }
        for line in lines {
            switch line.kind {
            case .deletion:
                if !additions.isEmpty { flush() }
                deletions.append((line.id, line.text))
            case .addition:
                additions.append((line.id, line.text))
            case .context:
                flush()
            case .noNewline:
                continue
            }
        }
        flush()
        return result
    }

    /// The ranges of `old` and `new` that differ, by words (runs of letters, digits and `_`),
    /// runs of white space and single other characters. `nil` when the lines are equal, share
    /// less than a third of their text, or are too long to compare quickly.
    public static func changes(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>])? {
        compare(old: old, new: new).map { ($0.old, $0.new) }
    }

    struct Match {
        var old: [Range<Int>]
        var new: [Range<Int>]
        /// Characters the lines share.
        var common: Int
    }

    static func compare(old: String, new: String) -> Match? {
        guard old != new else { return nil }
        let a = tokens(old), b = tokens(new)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 60_000 else { return nil }

        // Longest common subsequence of tokens.
        let columns = b.count + 1
        var table = [Int32](repeating: 0, count: (a.count + 1) * columns)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i * columns + j] = a[i] == b[j]
                    ? table[(i + 1) * columns + j + 1] + 1
                    : max(table[(i + 1) * columns + j], table[i * columns + j + 1])
            }
        }
        var keptA = [Bool](repeating: false, count: a.count)
        var keptB = [Bool](repeating: false, count: b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                keptA[i] = true
                keptB[j] = true
                i += 1
                j += 1
            } else if table[(i + 1) * columns + j] >= table[i * columns + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        let common = zip(a, keptA).reduce(0) { $0 + ($1.1 ? $1.0.count : 0) }
        let longest = max(old.count, new.count)
        // Mostly rewritten: marking nearly every word says nothing the line color doesn't.
        guard common * 3 >= longest else { return nil }
        let oldRanges = ranges(a, kept: keptA), newRanges = ranges(b, kept: keptB)
        guard !oldRanges.isEmpty || !newRanges.isEmpty else { return nil }
        return Match(old: oldRanges, new: newRanges, common: common)
    }

    static func tokens(_ text: String) -> [Substring] {
        enum Class { case word, space, other }
        func classify(_ character: Character) -> Class {
            if character.isLetter || character.isNumber || character == "_" { return .word }
            if character.isWhitespace { return .space }
            return .other
        }
        var tokens: [Substring] = []
        var start = text.startIndex
        var current: Class?
        var index = text.startIndex
        while index < text.endIndex {
            let kind = classify(text[index])
            if let current, current == kind, kind != .other {
                // Still the same word or space run.
            } else if index > start {
                tokens.append(text[start ..< index])
                start = index
            }
            current = kind
            index = text.index(after: index)
        }
        if start < text.endIndex { tokens.append(text[start...]) }
        return tokens
    }

    /// Character ranges of the tokens that aren't kept, with neighbors merged.
    private static func ranges(_ tokens: [Substring], kept: [Bool]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = 0
        for (token, isKept) in zip(tokens, kept) {
            let length = token.count
            if !isKept {
                if let last = ranges.last, last.upperBound == offset {
                    ranges[ranges.count - 1] = last.lowerBound ..< offset + length
                } else {
                    ranges.append(offset ..< offset + length)
                }
            }
            offset += length
        }
        return ranges
    }
}
