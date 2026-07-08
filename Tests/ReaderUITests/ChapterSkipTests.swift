#if os(macOS)
import ReaderCore
import Testing

@testable import ReaderUI

/// Status-bar ⇤ ⇥ section skipping: EVERY outline entry (any depth) is a
/// stop — the owner wants section-granular movement, not chapter jumps.
@Suite("Section skipping")
struct SectionSkipTests {
    private var outline: [OutlineNode] {
        [
            OutlineNode(
                label: "Chapter 1", entry: NavEntry(pageIndex: 4),
                children: [
                    OutlineNode(label: "1A", entry: NavEntry(pageIndex: 6), children: nil)
                ]
            ),
            OutlineNode(label: "Chapter 2", entry: NavEntry(pageIndex: 30), children: nil),
            OutlineNode(label: "Chapter 3", entry: NavEntry(pageIndex: 61), children: nil),
        ]
    }

    @Test func nextStopsAtEveryOutlineLevel() {
        #expect(OutlineNode.sectionStart(in: outline, after: 0) == 4)
        // Nested section 1A (page 6) IS a stop.
        #expect(OutlineNode.sectionStart(in: outline, after: 4) == 6)
        #expect(OutlineNode.sectionStart(in: outline, after: 6) == 30)
        #expect(OutlineNode.sectionStart(in: outline, after: 61) == nil)
    }

    @Test func previousGoesToEarlierSectionFromASectionStart() {
        // Media-player behavior: standing ON a section's first page skips
        // back to the one before it.
        #expect(OutlineNode.sectionStart(in: outline, before: 30) == 6)
        #expect(OutlineNode.sectionStart(in: outline, before: 6) == 4)
        #expect(OutlineNode.sectionStart(in: outline, before: 4) == nil)
    }

    @Test func emptyOutlineHasNoStops() {
        #expect(OutlineNode.sectionStart(in: [], after: 10) == nil)
        #expect(OutlineNode.sectionStart(in: [], before: 10) == nil)
    }
}
#endif
