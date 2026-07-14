import CoreGraphics
import Testing
@testable import ReaderUI

/// PURE even/odd book-pairing math (phase 5, VM-5) and the `/PageLayout`
/// name → `BookLayout` mapping (VM-6). No PDFKit — the pairing rule and the
/// catalog-name mapping are string/integer functions pinned exactly here; the
/// live `/PageLayout` fixture round-trip lives in ViewModePlannerIntegrationTests.
///
/// Model recap (docs/PDFKIT-FACTS.md §3): with `displaysAsBook` OFF pages pair
/// (0,1),(2,3),…; with it ON page 0 sits ALONE on the right and pairs are
/// (1,2),(3,4),…. Skim's rule: "index i starts a pair when (i % 2 == 1) ==
/// displaysAsBook". `displaysRTL` swaps which page of a pair is on the left.
@Suite struct BookLayoutTests {
    // MARK: BookLayout default

    /// The sensible default is a plain LTR non-book layout (pairs 0,1 | 2,3 …).
    @Test func bookLayoutDefaultIsPlainLTR() {
        #expect(BookLayout.default == BookLayout(displaysAsBook: false, rtl: false))
        #expect(BookLayout().displaysAsBook == false)
        #expect(BookLayout().rtl == false)
    }

    // MARK: VM-5 — pure pairing (pair(containing:layout:))

    /// VM-5 — displaysAsBook = FALSE, LTR: pages pair (0,1),(2,3),(4,5)…; the
    /// left page is the even index. The pure function returns the computed
    /// indices verbatim (a right index past the page count is the CALLER's job
    /// to null out — the pure math has no page count).
    @Test func vm5_bookPairing_notBook_ltr_pairsEvenOdd() {
        let layout = BookLayout(displaysAsBook: false, rtl: false)
        #expect(ViewModePlanner.pair(containing: 0, layout: layout) == (left: 0, right: 1))
        #expect(ViewModePlanner.pair(containing: 1, layout: layout) == (left: 0, right: 1))
        #expect(ViewModePlanner.pair(containing: 2, layout: layout) == (left: 2, right: 3))
        #expect(ViewModePlanner.pair(containing: 3, layout: layout) == (left: 2, right: 3))
        #expect(ViewModePlanner.pair(containing: 4, layout: layout) == (left: 4, right: 5))
        #expect(ViewModePlanner.pair(containing: 5, layout: layout) == (left: 4, right: 5))
        // Negative clamps to 0.
        #expect(ViewModePlanner.pair(containing: -3, layout: layout) == (left: 0, right: 1))
    }

    /// VM-5 — displaysAsBook = TRUE, LTR: page 0 sits ALONE on the RIGHT
    /// (left = nil, right = 0); thereafter pairs are (1,2),(3,4),(5,6)….
    @Test func vm5_bookPairing_book_ltr_index0LoneOnRight() {
        let layout = BookLayout(displaysAsBook: true, rtl: false)
        #expect(ViewModePlanner.pair(containing: 0, layout: layout) == (left: nil, right: 0))
        #expect(ViewModePlanner.pair(containing: 1, layout: layout) == (left: 1, right: 2))
        #expect(ViewModePlanner.pair(containing: 2, layout: layout) == (left: 1, right: 2))
        #expect(ViewModePlanner.pair(containing: 3, layout: layout) == (left: 3, right: 4))
        #expect(ViewModePlanner.pair(containing: 4, layout: layout) == (left: 3, right: 4))
        #expect(ViewModePlanner.pair(containing: 5, layout: layout) == (left: 5, right: 6))
    }

    /// VM-5 — displaysRTL = TRUE swaps the left/right slots of a pair. Not a
    /// book: (0,1) → left 1, right 0.
    @Test func vm5_bookPairing_notBook_rtl_swapsSides() {
        let layout = BookLayout(displaysAsBook: false, rtl: true)
        #expect(ViewModePlanner.pair(containing: 0, layout: layout) == (left: 1, right: 0))
        #expect(ViewModePlanner.pair(containing: 1, layout: layout) == (left: 1, right: 0))
        #expect(ViewModePlanner.pair(containing: 2, layout: layout) == (left: 3, right: 2))
        #expect(ViewModePlanner.pair(containing: 3, layout: layout) == (left: 3, right: 2))
    }

    /// VM-5 — displaysAsBook = TRUE and RTL: the lone page 0 now sits on the
    /// LEFT (left = 0, right = nil); interior pairs swap too.
    @Test func vm5_bookPairing_book_rtl_index0LoneOnLeft() {
        let layout = BookLayout(displaysAsBook: true, rtl: true)
        #expect(ViewModePlanner.pair(containing: 0, layout: layout) == (left: 0, right: nil))
        #expect(ViewModePlanner.pair(containing: 1, layout: layout) == (left: 2, right: 1))
        #expect(ViewModePlanner.pair(containing: 2, layout: layout) == (left: 2, right: 1))
        #expect(ViewModePlanner.pair(containing: 3, layout: layout) == (left: 4, right: 3))
    }

    /// VM-5 — the spread ANCHOR the transitions use is the LEFT page's index
    /// (the top-left slot), falling back to the lone page when the left slot is
    /// empty. Under the default layout this equals the old `(i/2)*2` rule so
    /// phase-4 behavior is preserved; under displaysAsBook it shifts by one.
    @Test func vm5_spreadLeftIndex_isTopLeftAnchor() {
        let plain = BookLayout(displaysAsBook: false, rtl: false)
        #expect(ViewModePlanner.spreadLeftIndex(of: 4, layout: plain) == 4)
        #expect(ViewModePlanner.spreadLeftIndex(of: 5, layout: plain) == 4)
        #expect(ViewModePlanner.spreadLeftIndex(of: 0, layout: plain) == 0)

        let book = BookLayout(displaysAsBook: true, rtl: false)
        // (3,4) pair → left anchor 3, not 4.
        #expect(ViewModePlanner.spreadLeftIndex(of: 4, layout: book) == 3)
        #expect(ViewModePlanner.spreadLeftIndex(of: 3, layout: book) == 3)
        // Lone page 0 (left slot empty) → anchor on the page itself.
        #expect(ViewModePlanner.spreadLeftIndex(of: 0, layout: book) == 0)

        // RTL top-left is the higher-numbered page of the pair.
        let rtl = BookLayout(displaysAsBook: false, rtl: true)
        #expect(ViewModePlanner.spreadLeftIndex(of: 2, layout: rtl) == 3)
    }

    // MARK: VM-6 — /PageLayout name → BookLayout mapping (pure)

    /// VM-6 — the PDF catalog `/PageLayout` name maps to a `BookLayout`: the
    /// "…Right" variants (1-based odd pages on the right, i.e. page index 0
    /// alone) → displaysAsBook true; everything else (and a missing key) →
    /// the default. No RTL is inferred from `/PageLayout`.
    @Test func vm6_pageLayoutName_mapsToBookLayout() {
        #expect(ViewModePlanner.bookLayout(pageLayoutName: "TwoPageRight")
            == BookLayout(displaysAsBook: true, rtl: false))
        #expect(ViewModePlanner.bookLayout(pageLayoutName: "TwoColumnRight")
            == BookLayout(displaysAsBook: true, rtl: false))

        for name in ["SinglePage", "OneColumn", "TwoColumnLeft", "TwoPageLeft"] {
            #expect(ViewModePlanner.bookLayout(pageLayoutName: name) == .default,
                    "\(name) should map to the default (not a book)")
        }
        // Missing / unknown → default.
        #expect(ViewModePlanner.bookLayout(pageLayoutName: nil) == .default)
        #expect(ViewModePlanner.bookLayout(pageLayoutName: "Bogus") == .default)
    }

    // MARK: VM-5 — pairing threaded through the transitions

    /// VM-5 — a transition's `targetPageIndex` (the pair's top-left anchor) uses
    /// the book pairing. single→double from page 4 with displaysAsBook lands on
    /// the (3,4) pair → left 3, whereas the DEFAULT layout pairs (4,5) → left 4.
    /// The destination `BookLayout` is carried through so the applier can set
    /// `displaysAsBook` / `displaysRTL` on the live view.
    @Test func vm5_transition_singleToDouble_bookLayout_landsOnLeftPage() {
        let viewport = CGSize(width: 824, height: 1000)
        let pageSize = CGSize(width: 400, height: 600)
        let book = BookLayout(displaysAsBook: true, rtl: false)

        let t = ViewModePlanner.transition(
            from: .singleContinuous, to: .doubleContinuous,
            currentPageIndex: 4, currentScale: 1.0,
            viewport: viewport, pageSize: pageSize, layout: book)
        #expect(t.displayMode == 3)
        #expect(t.targetPageIndex == 3)                 // (3,4) pair → left 3
        #expect(t.bookLayout == book)

        // The default layout (no arg) preserves phase-4 behavior: (4,5) → 4.
        let plain = ViewModePlanner.transition(
            from: .singleContinuous, to: .doubleContinuous,
            currentPageIndex: 4, currentScale: 1.0,
            viewport: viewport, pageSize: pageSize)
        #expect(plain.targetPageIndex == 4)
        #expect(plain.bookLayout == .default)
    }

    /// VM-5 — double→single (SW-2 path) also anchors on the book pair's top-left
    /// page: from page 4 with displaysAsBook the former top-left is page 3.
    @Test func vm5_transition_doubleToSingle_bookLayout_landsOnFormerLeftPage() {
        let viewport = CGSize(width: 824, height: 1000)
        let pageSize = CGSize(width: 400, height: 600)
        let book = BookLayout(displaysAsBook: true, rtl: false)

        let t = ViewModePlanner.transition(
            from: .doubleContinuous, to: .singleContinuous,
            currentPageIndex: 4, currentScale: 1.0,
            viewport: viewport, pageSize: pageSize, layout: book)
        #expect(t.displayMode == 1)
        #expect(t.targetPageIndex == 3)                 // former (3,4) pair → left 3
        #expect(t.scrollAnchor == .pageTopMargin(pageIndex: 3))
    }
}
