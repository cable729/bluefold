#if os(macOS)
import ReaderCore
import Testing

@testable import ReaderUI

/// Status-bar |‹ ›| chapter skipping: boundaries are TOP-LEVEL outline
/// entries only (sections inside a chapter don't count as stops).
@Suite("Chapter skipping")
struct ChapterSkipTests {
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

    @Test func nextStopsAtTopLevelChaptersOnly() {
        #expect(OutlineNode.chapterStart(in: outline, after: 0) == 4)
        // From inside chapter 1 (past section 1A): next is chapter 2, not 1A.
        #expect(OutlineNode.chapterStart(in: outline, after: 5) == 30)
        #expect(OutlineNode.chapterStart(in: outline, after: 30) == 61)
        #expect(OutlineNode.chapterStart(in: outline, after: 61) == nil)
    }

    @Test func previousGoesToEarlierChapterFromAChapterStart() {
        // Media-player behavior: standing ON chapter 2's first page skips
        // back to chapter 1, not to chapter 2's own start.
        #expect(OutlineNode.chapterStart(in: outline, before: 30) == 4)
        #expect(OutlineNode.chapterStart(in: outline, before: 45) == 30)
        #expect(OutlineNode.chapterStart(in: outline, before: 4) == nil)
    }

    @Test func emptyOutlineHasNoStops() {
        #expect(OutlineNode.chapterStart(in: [], after: 10) == nil)
        #expect(OutlineNode.chapterStart(in: [], before: 10) == nil)
    }
}
#endif
