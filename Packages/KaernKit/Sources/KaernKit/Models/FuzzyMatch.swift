import Foundation

/// Quick-switcher matching: the query's characters in order, case-insensitively. Contiguous
/// runs, word starts ("/", "-", "_", ".", " ") and early matches score higher. `offsets` are the
/// matched character positions, for bolding them.
public struct FuzzyMatch: Sendable, Hashable, Comparable {
    public var score: Int
    public var offsets: [Int]

    public init(score: Int, offsets: [Int]) {
        self.score = score
        self.offsets = offsets
    }

    /// Everything matches an empty query, with nothing to bold.
    public static let everything = FuzzyMatch(score: 0, offsets: [])
    public static func < (lhs: FuzzyMatch, rhs: FuzzyMatch) -> Bool { lhs.score < rhs.score }

    public static func match(_ query: String, in text: String) -> FuzzyMatch? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return .everything }
        let haystack = Array(text.lowercased())
        guard needle.count <= haystack.count else { return nil }

        // A contiguous occurrence beats any scattered match.
        if let start = firstOccurrence(of: needle, in: haystack) {
            var score = 1000 - min(start, 200) + needle.count * 10
            if start == 0 || isBoundary(haystack, at: start) { score += 150 }
            if needle.count == haystack.count { score += 200 }
            return FuzzyMatch(score: score, offsets: Array(start ..< start + needle.count))
        }

        if let offsets = subsequence(needle, in: haystack, atWordStarts: true)
            ?? subsequence(needle, in: haystack, atWordStarts: false) {
            var score = 0
            var previous = -2
            for index in offsets {
                if index == previous + 1 {
                    score += 15
                } else if isBoundary(haystack, at: index) {
                    score += 10
                } else {
                    score += 1
                }
                previous = index
            }
            score -= (offsets.last! - offsets.first!) - needle.count
            return FuzzyMatch(score: score, offsets: offsets)
        }
        return nil
    }

    /// The query's characters in order. With `atWordStarts`, each one must start a word or follow
    /// the previous match ("fra" → **f**eature/**r**estore-**a**utomatic).
    private static func subsequence(_ needle: [Character], in haystack: [Character], atWordStarts: Bool) -> [Int]? {
        var offsets: [Int] = []
        offsets.reserveCapacity(needle.count)
        var index = 0
        var previous = -2
        for character in needle {
            while index < haystack.count {
                if haystack[index] == character,
                   !atWordStarts || index == previous + 1 || isBoundary(haystack, at: index) {
                    break
                }
                index += 1
            }
            guard index < haystack.count else { return nil }
            offsets.append(index)
            previous = index
            index += 1
        }
        return offsets
    }

    private static func isBoundary(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        return ["/", "-", "_", ".", " ", ":"].contains(characters[index - 1])
    }

    private static func firstOccurrence(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var start = 0
        while start + needle.count <= haystack.count {
            if haystack[start] == needle[0], Array(haystack[start ..< start + needle.count]) == needle {
                return start
            }
            start += 1
        }
        return nil
    }
}
