import Testing
@testable import KaernKit

@Suite("Fuzzy matching")
struct FuzzyMatchTests {
    @Test func prefersContiguousWordStartMatches() throws {
        let contiguous = try #require(FuzzyMatch.match("rest", in: "feature/restore-automatic-alpha"))
        #expect(contiguous.offsets == [8, 9, 10, 11])
        let scattered = try #require(FuzzyMatch.match("rest", in: "release-notes-template"))
        #expect(contiguous > scattered)
        let exact = try #require(FuzzyMatch.match("main", in: "main"))
        let longer = try #require(FuzzyMatch.match("main", in: "origin/main"))
        #expect(exact > longer)
    }

    @Test func matchesSubsequencesCaseInsensitively() throws {
        let match = try #require(FuzzyMatch.match("FRA", in: "feature/restore-automatic-alpha"))
        #expect(match.offsets == [0, 8, 16])
        #expect(FuzzyMatch.match("xyz", in: "feature/restore") == nil)
        #expect(FuzzyMatch.match("", in: "anything")?.offsets == [])
    }
}
