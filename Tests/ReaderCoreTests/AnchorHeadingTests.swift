import Foundation
import Testing
@testable import ReaderCore

@Suite struct AnchorHeadingTests {
    // MARK: - Number-first (LADR 4th edition style)

    @Test func ladrDefinition() {
        let heading = AnchorHeadingParser.parse(line: "5.2 definition: invariant subspace")
        #expect(heading == .init(kind: .definition, label: "5.2 definition: invariant subspace"))
    }

    @Test func ladrExampleWithLongTitle() {
        let heading = AnchorHeadingParser.parse(
            line: "5.4 example: four invariant subspaces, not necessarily all different"
        )
        #expect(heading?.kind == .example)
        #expect(heading?.label.hasPrefix("5.4 example: four invariant subspaces") == true)
    }

    @Test func numberFirstRequiresColon() {
        // Bare "number word" lines are prose (page numbers, list items).
        #expect(AnchorHeadingParser.parse(line: "5.2 definition of a subspace") == nil)
    }

    @Test func numberFirstAllowsSectionLetterNumbers() {
        let heading = AnchorHeadingParser.parse(line: "3.5A theorem: fundamental theorem")
        #expect(heading?.kind == .theorem)
    }

    // MARK: - Keyword-first (classic LaTeX style)

    @Test func classicTheoremWithName() {
        let heading = AnchorHeadingParser.parse(
            line: "Theorem 2.2.1 (Axiom of Completeness). Every nonempty set…"
        )
        #expect(heading == .init(kind: .theorem, label: "Theorem 2.2.1 (Axiom of Completeness)"))
    }

    @Test func classicTheoremBareAtEndOfLine() {
        let heading = AnchorHeadingParser.parse(line: "Lemma 23.1")
        #expect(heading == .init(kind: .theorem, label: "Lemma 23.1"))
    }

    @Test func classicDefinitionWithColon() {
        let heading = AnchorHeadingParser.parse(line: "Definition 1.4.2: A set is countable when…")
        #expect(heading?.kind == .definition)
        #expect(heading?.label == "Definition 1.4.2")
    }

    @Test func undottedNumberWithExplicitTerminator() {
        // Per-chapter numbering (Ross-style) — round-16 owner feedback.
        #expect(AnchorHeadingParser.parse(line: "Example 3. Rolling two dice…")
            == .init(kind: .example, label: "Example 3"))
        #expect(AnchorHeadingParser.parse(line: "Remark 12: on notation")?.kind == .example)
        #expect(AnchorHeadingParser.parse(line: "Lemma 4 (Zorn). Every chain…")
            == .init(kind: .theorem, label: "Lemma 4 (Zorn)"))
        // Undotted + bare end of line = wrapped reference ("…see\nTheorem 5").
        #expect(AnchorHeadingParser.parse(line: "Theorem 5") == nil)
    }

    // MARK: - Chapter and section headings (structure printed in the text)

    @Test func chapterHeadings() {
        #expect(AnchorHeadingParser.parse(line: "Chapter 7")
            == .init(kind: .chapter, label: "Chapter 7"))
        #expect(AnchorHeadingParser.parse(line: "Chapter 7 Linear Maps")
            == .init(kind: .chapter, label: "Chapter 7 Linear Maps"))
        #expect(AnchorHeadingParser.parse(line: "APPENDIX A Sets and Functions")?.kind == .chapter)
        #expect(AnchorHeadingParser.parse(line: "Part III")?.kind == .chapter)
    }

    @Test func chapterFalsePositives() {
        // Wrapped prose: "…as we saw in\nChapter 7." / "…in\nchapter 7".
        #expect(AnchorHeadingParser.parse(line: "Chapter 7.") == nil)
        #expect(AnchorHeadingParser.parse(line: "chapter 7") == nil)
        #expect(AnchorHeadingParser.parse(line: "Chapter 7 and Chapter 8 cover this") == nil)
    }

    @Test func numberedSectionHeadings() {
        #expect(AnchorHeadingParser.parse(line: "1.3 The Axiom of Completeness")
            == .init(kind: .section, label: "1.3 The Axiom of Completeness"))
        #expect(AnchorHeadingParser.parse(line: "4.6 Applications to Vector Calculus")?.kind == .section)
        #expect(AnchorHeadingParser.parse(line: "2.3.1 Uniform Convergence")?.kind == .subsection)
    }

    @Test func numberFirstWithoutColonKeepsKeywordOnly() {
        // Hrbacek/Jech: the statement runs on in the same line.
        #expect(AnchorHeadingParser.parse(
            line: "2.11 Definition The membership relation on A is defined by"
        ) == .init(kind: .definition, label: "2.11 Definition"))
        #expect(AnchorHeadingParser.parse(line: "3.8 Example")
            == .init(kind: .example, label: "3.8 Example"))
        // The lowercase no-colon form is prose, not a heading.
        #expect(AnchorHeadingParser.parse(line: "5.2 definition of a subspace") == nil)
    }

    @Test func rejectsExerciseSentences() {
        // Hrbacek exercise pages, real cases.
        #expect(AnchorHeadingParser.parse(
            line: "2.6 Prove that for any three binary relations R, S, and T"
        ) == nil)
        #expect(AnchorHeadingParser.parse(
            line: "2.7 Give examples of sets X, Y, and Z such that"
        ) == nil)
    }

    @Test func numberedSectionFalsePositives() {
        // Running head with trailing page number (Tu p.59, real case).
        #expect(AnchorHeadingParser.parse(line: "4.6 Applications to Vector Calculus 41") == nil)
        // Bare list-item numbers (Axler exercise pages, real case).
        #expect(AnchorHeadingParser.parse(line: "7 Suppose that 𝑚 is a nonnegative integer") == nil)
        // Sentences after a wrapped reference number.
        #expect(AnchorHeadingParser.parse(line: "5.4 Suppose T ∈ ℒ(V). Then U is invariant") == nil)
        #expect(AnchorHeadingParser.parse(line: "2.2 and the result follows") == nil)
        // Displayed math with an equation-ish shape.
        #expect(AnchorHeadingParser.parse(line: "3.1 A = LU decomposition of A") == nil)
    }

    // MARK: - False-positive guards

    @Test func rejectsMidProseWrappedReference() {
        // Real line from Axler p.151 — a wrapped prose sentence that starts
        // with a keyword. The undotted number is the tell.
        #expect(AnchorHeadingParser.parse(
            line: "Exercise 21 in Section 5D shows how linear algebra can be used"
        ) == nil)
    }

    @Test func rejectsDottedNumberFollowedByProse() {
        // "Theorem 5.19 and Exercise 29 …" — no terminator after the number.
        #expect(AnchorHeadingParser.parse(
            line: "Theorem 5.19 and Exercise 29 in Section 5B."
        ) == nil)
    }

    @Test func rejectsLowercaseWrappedReference() {
        // "…as shown by\ntheorem 2.2.1." — lowercase keyword at line start.
        #expect(AnchorHeadingParser.parse(line: "theorem 2.2.1.") == nil)
    }

    @Test func rejectsPlainProse() {
        #expect(AnchorHeadingParser.parse(line: "Suppose T ∈ L(V). If m ≥ 2 and") == nil)
        #expect(AnchorHeadingParser.parse(line: "130 Chapter 4 Polynomials") == nil)
        #expect(AnchorHeadingParser.parse(line: "") == nil)
    }

    @Test func truncatesVeryLongLabels() {
        let title = String(repeating: "very long title ", count: 10)
        let heading = AnchorHeadingParser.parse(line: "5.1 definition: \(title)")
        #expect(heading != nil)
        #expect((heading?.label.count ?? 0) <= 70)
        #expect(heading?.label.hasSuffix("…") == true)
    }
}
