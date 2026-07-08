import Foundation

/// Result of a fuzzy match: a comparable score and the character offsets in
/// the candidate that matched (for highlight rendering).
public struct FuzzyMatch: Equatable, Sendable {
    public var score: Int
    public var matchedIndices: [Int]

    public init(score: Int, matchedIndices: [Int]) {
        self.score = score
        self.matchedIndices = matchedIndices
    }
}

/// Case-insensitive subsequence matcher with VS Code-style scoring: every
/// query character must appear in order in the candidate; consecutive runs,
/// word starts, and camelCase humps score higher than scattered hits.
///
/// Deliberately greedy (first viable position per character) — palettes rank
/// dozens-to-hundreds of short strings, where greedy + boundary bonuses is
/// indistinguishable from optimal alignment and much simpler. Ties should be
/// broken by the caller (shorter candidate / original order).
public enum FuzzyMatcher {
    /// Nil when `query` is not a subsequence of `candidate`. Whitespace in
    /// the query is ignored ("ch 1" matches "Chapter 1"). An empty query
    /// matches everything with score 0.
    public static func match(query: String, in candidate: String) -> FuzzyMatch? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, matchedIndices: []) }

        let chars = Array(candidate)
        let lower = Array(candidate.lowercased())
        guard needle.count <= lower.count else { return nil }

        var indices: [Int] = []
        indices.reserveCapacity(needle.count)
        var score = 0
        var previous = -2
        var qi = 0

        for i in lower.indices where qi < needle.count {
            guard lower[i] == needle[qi] else { continue }
            var bonus = 1
            if i == previous + 1 { bonus += 4 }  // consecutive run
            if i == 0 {
                bonus += 4  // start of string
            } else if !chars[i - 1].isLetter && !chars[i - 1].isNumber {
                bonus += 3  // word boundary (space, punctuation, "›")
            } else if chars[i].isUppercase && chars[i - 1].isLowercase {
                bonus += 2  // camelCase hump
            }
            score += bonus
            indices.append(i)
            previous = i
            qi += 1
        }

        guard qi == needle.count else { return nil }
        return FuzzyMatch(score: score, matchedIndices: indices)
    }
}
