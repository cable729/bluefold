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
