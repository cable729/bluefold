import Foundation

/// What a margin anchor points at — drives the glyph and (later) filtering.
public enum AnchorKind: String, Equatable, Sendable {
    case chapter
    case section
    case subsection
    /// Theorem-family results: theorem, lemma, corollary, proposition,
    /// claim, fact, algorithm.
    case theorem
    /// definition, notation.
    case definition
    /// example, remark.
    case example
    case exercise
    case equation
    case other
}

/// Detects theorem/definition/example headings in extracted page text —
/// the anchor tier that works when a book has no usable named destinations
/// (most do not: probed 2026-07-08, Axler has no theorem.* names and Tu has
/// none at all).
///
/// Two heading shapes cover the library:
///  - number-first (LADR 4th): `5.2 definition: invariant subspace` —
///    the colon is required; it is what separates a heading from prose.
///  - keyword-first (classic): `Theorem 2.2.1 (Axiom of Completeness).` —
///    requires a DOTTED number and a terminator right after it, which
///    rejects mid-prose line-wrap starts like
///    "Exercise 21 in Section 5D shows how…" (real false positive, Axler
///    p.151).
public enum AnchorHeadingParser {
    public struct Heading: Equatable, Sendable {
        public let kind: AnchorKind
        /// Display label, e.g. "5.2 definition: invariant subspace" or
        /// "Theorem 2.2.1 (Axiom of Completeness)". Truncated to fit chrome.
        public let label: String

        public init(kind: AnchorKind, label: String) {
            self.kind = kind
            self.label = label
        }
    }

    /// Keyword → kind bucket. Lowercase keys; matching is case-insensitive.
    private static let kinds: [String: AnchorKind] = [
        "theorem": .theorem, "lemma": .theorem, "corollary": .theorem,
        "proposition": .theorem, "claim": .theorem, "fact": .theorem,
        "algorithm": .theorem,
        "definition": .definition, "notation": .definition,
        "example": .example, "remark": .example,
        "exercise": .exercise,
    ]

    private static let keywordAlternation = kinds.keys.sorted().joined(separator: "|")

    /// `5.2 definition: invariant subspace` — number, keyword, REQUIRED
    /// colon. Case-insensitive (LADR sets these lowercase).
    private static let numberFirst = try! NSRegularExpression(
        pattern: #"^\s*(\d+(?:\.\d+)*[A-Za-z]?)\s+(\#(keywordAlternation))\s*:\s*(\S.*)?$"#,
        options: [.caseInsensitive]
    )

    /// `Theorem 2.2.1 (Axiom of Completeness).` — keyword, dotted number,
    /// optional parenthetical name, then a terminator (`.`/`:` or end of
    /// line). The dotted-number and terminator requirements are the
    /// false-positive guards.
    private static let keywordFirst = try! NSRegularExpression(
        pattern: #"^\s*(\#(keywordAlternation))\s+(\d+(?:\.\d+)+[a-z]?)\s*(\([^()]{1,60}\))?\s*([.:]|$)"#,
        options: [.caseInsensitive]
    )

    private static let maxLabelLength = 70

    /// Parses one extracted text line; nil when it is not a heading.
    public static func parse(line: String) -> Heading? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)

        if let match = numberFirst.firstMatch(in: line, range: range) {
            let number = ns.substring(with: match.range(at: 1))
            let keyword = ns.substring(with: match.range(at: 2))
            let title = match.range(at: 3).location == NSNotFound
                ? "" : ns.substring(with: match.range(at: 3))
            guard let kind = kinds[keyword.lowercased()] else { return nil }
            var label = "\(number) \(keyword.lowercased()):"
            if !title.isEmpty { label += " \(title)" }
            return Heading(kind: kind, label: truncate(label))
        }

        if let match = keywordFirst.firstMatch(in: line, range: range) {
            let keyword = ns.substring(with: match.range(at: 1))
            // An all-lowercase keyword at line start is a wrapped prose
            // reference ("…by\ntheorem 2.2.1."), not a heading.
            guard keyword.first?.isUppercase == true,
                  let kind = kinds[keyword.lowercased()] else { return nil }
            let number = ns.substring(with: match.range(at: 2))
            var label = "\(keyword) \(number)"
            if match.range(at: 3).location != NSNotFound {
                label += " \(ns.substring(with: match.range(at: 3)))"
            }
            return Heading(kind: kind, label: truncate(label))
        }

        return nil
    }

    // MARK: - Named-destination classification

    /// hyperref destination-name prefixes → anchor kind + display word.
    /// Whitelist: names with any other prefix (page.*, cite.*, Item.*,
    /// equation.*, Hfootnote.*, figure.* …) are navigation noise, not
    /// margin anchors.
    private static let destinationKinds: [String: (kind: AnchorKind, word: String)] = [
        "chapter": (.chapter, "Chapter"), "appendix": (.chapter, "Appendix"),
        "section": (.section, "Section"),
        "subsection": (.subsection, "Section"), "subsubsection": (.subsection, "Section"),
        "theorem": (.theorem, "Theorem"), "thm": (.theorem, "Theorem"),
        "lemma": (.theorem, "Lemma"), "lem": (.theorem, "Lemma"),
        "corollary": (.theorem, "Corollary"), "cor": (.theorem, "Corollary"),
        "proposition": (.theorem, "Proposition"), "prop": (.theorem, "Proposition"),
        "definition": (.definition, "Definition"), "defn": (.definition, "Definition"),
        "example": (.example, "Example"), "remark": (.example, "Remark"),
        "exercise": (.exercise, "Exercise"), "exer": (.exercise, "Exercise"),
    ]

    /// Classifies a PDF named destination (`theorem.112.2.2.1`,
    /// `section.5.1`) into an anchor heading, or nil for non-anchor names.
    ///
    /// Labels are a best-effort prettification — theorem-family names carry
    /// hyperref's internal counter as the FIRST numeric token
    /// (`theorem.112.2.2.1` displays as "Theorem 2.2.1"), so it is dropped
    /// when more tokens follow. A text-detected label at the same spot
    /// always wins over this guess (AnchorIndex dedupe).
    public static func classifyDestination(_ name: String) -> Heading? {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count >= 2,
              let (kind, word) = destinationKinds[parts[0].lowercased()] else {
            return nil
        }
        var numbers = Array(parts.dropFirst())
        let isTheoremFamily: Bool = [.theorem, .definition, .example, .exercise].contains(kind)
        if isTheoremFamily, numbers.count >= 2 {
            numbers.removeFirst()
        }
        return Heading(kind: kind, label: "\(word) \(numbers.joined(separator: "."))")
    }

    private static func truncate(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxLabelLength else { return trimmed }
        return String(trimmed.prefix(maxLabelLength - 1)) + "…"
    }
}
