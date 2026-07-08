import Testing

@testable import ReaderUI

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    @Test func exactSubstringMatches() {
        let match = FuzzyMatcher.match(query: "page", in: "Go to Page…")
        #expect(match != nil)
        #expect(match?.matchedIndices == [6, 7, 8, 9])
    }

    @Test func subsequenceMatches() {
        #expect(FuzzyMatcher.match(query: "nxt", in: "Next Tab") != nil)
        #expect(FuzzyMatcher.match(query: "ctab", in: "Close Other Tabs") != nil)
    }

    @Test func outOfOrderDoesNotMatch() {
        #expect(FuzzyMatcher.match(query: "tn", in: "Next Tab") == nil)
    }

    @Test func missingCharacterDoesNotMatch() {
        #expect(FuzzyMatcher.match(query: "zed", in: "Next Tab") == nil)
    }

    @Test func caseInsensitive() {
        let match = FuzzyMatcher.match(query: "NeXT", in: "next tab")
        #expect(match?.matchedIndices == [0, 1, 2, 3])
    }

    @Test func emptyQueryMatchesEverything() {
        let match = FuzzyMatcher.match(query: "", in: "anything")
        #expect(match == FuzzyMatch(score: 0, matchedIndices: []))
        #expect(FuzzyMatcher.match(query: "   ", in: "anything")?.score == 0)
    }

    @Test func whitespaceInQueryIsIgnored() {
        #expect(FuzzyMatcher.match(query: "ch 1", in: "Chapter 1") != nil)
    }

    @Test func queryLongerThanCandidateDoesNotMatch() {
        #expect(FuzzyMatcher.match(query: "chapter one", in: "ch 1") == nil)
    }

    @Test func wordBoundariesBeatScatteredMatches() {
        let boundary = FuzzyMatcher.match(query: "np", in: "Next Page")
        let scattered = FuzzyMatcher.match(query: "np", in: "unripe")
        #expect(boundary != nil && scattered != nil)
        #expect(boundary!.score > scattered!.score)
    }

    @Test func consecutiveRunBeatsGaps() {
        let consecutive = FuzzyMatcher.match(query: "tab", in: "Tab")
        let gapped = FuzzyMatcher.match(query: "tab", in: "t-a-b")
        #expect(consecutive!.score > gapped!.score)
    }

    @Test func matchedIndicesAlignWithCharacters() {
        let match = FuzzyMatcher.match(query: "gp", in: "Go to Page")
        #expect(match?.matchedIndices == [0, 6])
    }

    @Test func matchesAcrossBreadcrumbPaths() {
        // Breadcrumb search: query spanning path components still matches.
        #expect(FuzzyMatcher.match(query: "ch1 complex", in: "Chapter 1 › 1A › Complex Numbers") != nil)
        #expect(FuzzyMatcher.match(query: "1a numbers", in: "Chapter 1 › 1A › Complex Numbers") != nil)
    }
}
