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

    /// `Theorem 2.2.1 (Axiom of Completeness).` — keyword, number, optional
    /// parenthetical name, then a terminator. The terminator is the
    /// false-positive guard: it rejects mid-prose line-wrap starts like
    /// "Exercise 21 in Section 5D shows how…" (real case, Axler p.151).
    /// UNDOTTED numbers ("Example 3." — per-chapter numbering, round-16
    /// owner feedback) additionally require an EXPLICIT `.`/`:`/(name):
    /// end-of-line alone would re-admit wrapped references ("…see\nTheorem 5").
    private static let keywordFirst = try! NSRegularExpression(
        // (?!\d) — a "." terminator must not be a decimal point: with the
        // number's dots optional, "Theorem 5.19 and…" would otherwise
        // backtrack to number "5" + terminator "." mid-number.
        pattern: #"^\s*(\#(keywordAlternation))\s+(\d+(?:\.\d+)*[a-z]?)\s*(\([^()]{1,60}\))?\s*([.:](?!\d)|$)"#,
        options: [.caseInsensitive]
    )

    /// `2.11 Definition The membership relation…` (Hrbacek/Jech style) —
    /// number, CAPITALIZED keyword, no colon; the statement often runs on
    /// in the same line, so the label keeps only "number Keyword".
    /// Case-sensitive: the lowercase form without a colon is prose.
    private static let numberFirstNoColon = try! NSRegularExpression(
        pattern: {
            let capitalized = kinds.keys
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .sorted().joined(separator: "|")
            return #"^\s*(\d+(?:\.\d+)*[A-Za-z]?)\s+(\#(capitalized))\b"#
        }()
    )

    /// `Chapter 7`, `Chapter 7 Linear Maps`, `APPENDIX A`, `Part III` —
    /// alone or followed by a title. Wrapped prose protections: a lowercase
    /// word is rejected in code, and "…as we saw in Chapter 7." never
    /// matches because the number must be followed by a space or the end
    /// (no directly-attached period).
    private static let chapterFirst = try! NSRegularExpression(
        pattern: #"^\s*(Chapter|Appendix|Part)\s+(\d{1,3}|[A-Z]\b|[IVXLC]{1,6}\b)(\s+[^.:]+)?$"#,
        options: [.caseInsensitive]
    )

    /// `1.3 The Axiom of Completeness` — a numbered SECTION heading printed
    /// in the text, for books whose PDF outline is missing or shallower
    /// than their LaTeX numbering (round-16 owner feedback). Guards, each
    /// killing a real false-positive class:
    ///  - dotted number required — bare "7 Suppose 𝑚 is…" exercise-list
    ///    items never match,
    ///  - title starts uppercase — wrapped lowercase prose never matches,
    ///  - no `.`/`:` anywhere in the title — sentences ("5.4 Suppose
    ///    T ∈ ℒ(V). Then…") never match,
    ///  - must not END with a number — running heads carry a trailing page
    ///    number ("4.6 Applications to Vector Calculus 41", Tu p.59);
    ///    checked in code.
    private static let numberedHeading = try! NSRegularExpression(
        pattern: #"^\s*(\d{1,2}(?:\.\d{1,3}){1,3})\s+([A-Z][^.:]{2,55})$"#
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

        if let match = numberFirstNoColon.firstMatch(in: line, range: range) {
            let number = ns.substring(with: match.range(at: 1))
            let keyword = ns.substring(with: match.range(at: 2))
            if let kind = kinds[keyword.lowercased()] {
                return Heading(kind: kind, label: truncate("\(number) \(keyword)"))
            }
        }

        if let match = keywordFirst.firstMatch(in: line, range: range) {
            let keyword = ns.substring(with: match.range(at: 1))
            // An all-lowercase keyword at line start is a wrapped prose
            // reference ("…by\ntheorem 2.2.1."), not a heading.
            guard keyword.first?.isUppercase == true,
                  let kind = kinds[keyword.lowercased()] else { return nil }
            let number = ns.substring(with: match.range(at: 2))
            let hasParenName = match.range(at: 3).location != NSNotFound
            let terminator = ns.substring(with: match.range(at: 4))
            // Undotted number + bare end-of-line = a wrapped reference.
            if !number.contains("."), terminator.isEmpty, !hasParenName {
                return nil
            }
            var label = "\(keyword) \(number)"
            if hasParenName {
                label += " \(ns.substring(with: match.range(at: 3)))"
            }
            return Heading(kind: kind, label: truncate(label))
        }

        if let match = chapterFirst.firstMatch(in: line, range: range) {
            let word = ns.substring(with: match.range(at: 1))
            guard word.first?.isUppercase == true else { return nil }
            let number = ns.substring(with: match.range(at: 2))
            var label = "\(word.prefix(1).uppercased() + word.dropFirst().lowercased()) \(number)"
            if match.range(at: 3).location != NSNotFound {
                let title = ns.substring(with: match.range(at: 3))
                    .trimmingCharacters(in: .whitespaces)
                if isTitleLike(title) { label += " \(title)" } else { return nil }
            }
            return Heading(kind: .chapter, label: truncate(label))
        }

        if let match = numberedHeading.firstMatch(in: line, range: range) {
            let number = ns.substring(with: match.range(at: 1))
            let title = ns.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespaces)
            guard isTitleLike(title) else { return nil }
            let kind: AnchorKind = number.filter { $0 == "." }.count == 1
                ? .section : .subsection
            return Heading(kind: kind, label: truncate("\(number) \(title)"))
        }

        return nil
    }

    /// First words that start exercise statements and wrapped prose, never
    /// section titles — "2.6 Prove that for any three binary relations…"
    /// (Hrbacek exercise pages, real case).
    private static let sentenceStarters: Set<String> = [
        "Prove", "Show", "Suppose", "Let", "Give", "Find", "Verify",
        "Determine", "Assume", "Recall", "Evaluate", "Compute", "Use",
        "Consider", "Define", "Describe", "Explain", "Decide", "State",
        "If", "Then", "We", "It", "This", "That", "These", "Those",
        "There", "And", "But", "For", "Hence", "Thus", "Now", "So",
    ]

    /// A heading title, not a wrapped sentence or running head: starts
    /// uppercase ("Chapter 7 and Chapter 8…" wraps to a lowercase word),
    /// doesn't open like a sentence, no trailing page number, no
    /// sentence-ending comma, not math-ish.
    private static func isTitleLike(_ title: String) -> Bool {
        guard let first = title.first, let last = title.last else { return false }
        if !(first.isUppercase || first.isNumber) { return false }
        if last.isNumber || last == "," || last == ";" { return false }
        if title.contains("=") { return false }
        let firstWord = title.prefix(while: { !$0.isWhitespace })
        if sentenceStarters.contains(String(firstWord)) { return false }
        return true
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
