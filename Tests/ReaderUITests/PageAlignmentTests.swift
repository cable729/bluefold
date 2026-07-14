import CoreGraphics
import Testing
@testable import ReaderUI

/// PURE cell geometry + scale-source math for different-size pages (phase 6,
/// SIZE-1..SIZE-5). Every number is computed on paper from the page/cell sizes
/// and `ReaderLayout.margin`, asserted exactly — no PDFKit. The live-view checks
/// (box overrides honored, spread abuts the gutter, single-fixed re-fit) live in
/// PageBoxStoreTests (macOS only).
///
/// Mechanism (docs/PDFKIT-FACTS.md Fact 3): a page box ENLARGED past its content
/// renders the extra area blank with the content untouched. So a uniform two-up
/// cell + asymmetric padding positions each page's content spine-ward without
/// cropping. `cellBox` is that padding arithmetic; it never scales content
/// (SIZE-5 — small pages are never over-zoomed).
@Suite struct PageAlignmentTests {
    // MARK: SIZE-3 / SIZE-4 — cell geometry (content flush toward the spine)

    /// SIZE-3/4 — a narrow LEFT page and a full RIGHT page share a uniform cell.
    /// GIVEN left content 300×600, right content 400×600, cell 400×600, center.
    /// WHEN cellBox is computed for each slot:
    ///   LEFT slot ⇒ content flush RIGHT: padLeft = 400−300 = 100 ⇒
    ///     box.minX = content.maxX − cell.w = 300 − 400 = −100 ⇒ (−100,0,400,600).
    ///   RIGHT slot ⇒ content flush LEFT: padLeft = 0 ⇒ (0,0,400,600).
    ///   Both vertically centered (ph == cell.h ⇒ padBottom 0).
    /// THEN the two contents meet at the shared inner edge (left.maxX == 300 in
    ///   its box's right edge; right.minX == 0 in its box's left edge).
    @Test func size3_leftPagePadsLeft_rightPagePadsLeft_towardSpine() {
        let cell = CGSize(width: 400, height: 600)
        let leftBox = ViewModePlanner.cellBox(
            content: CGRect(x: 0, y: 0, width: 300, height: 600),
            cell: cell, side: .left, vAlign: .center)
        #expect(leftBox == CGRect(x: -100, y: 0, width: 400, height: 600))

        let rightBox = ViewModePlanner.cellBox(
            content: CGRect(x: 0, y: 0, width: 400, height: 600),
            cell: cell, side: .right, vAlign: .center)
        #expect(rightBox == CGRect(x: 0, y: 0, width: 400, height: 600))
    }

    /// SIZE-3/4 — a narrow RIGHT page pads on the RIGHT (content flush left).
    /// content 300×600, cell 400×600, right slot ⇒ box.minX = content.minX = 0,
    /// box width 400 ⇒ (0,0,400,600); the 100 pt of blank sits on the RIGHT.
    @Test func size3_narrowRightPage_padsRight() {
        let box = ViewModePlanner.cellBox(
            content: CGRect(x: 0, y: 0, width: 300, height: 600),
            cell: CGSize(width: 400, height: 600), side: .right, vAlign: .center)
        #expect(box == CGRect(x: 0, y: 0, width: 400, height: 600))
        // The content's left edge stays at the box's left edge (spine side); the
        // blank strip is on the right (box.maxX 400 − content.maxX 300 = 100).
        #expect(box.minX == 0)
        #expect(box.maxX - 300 == 100)
    }

    /// SIZE-4 — vertical CENTER: a SHORT page is centered top/bottom in the cell.
    /// content 400×500, cell 400×600 ⇒ padBottom = (600−500)/2 = 50 ⇒
    /// box.minY = content.minY − 50 = −50 ⇒ (0,−50,400,600).
    @Test func size4_shortPage_verticallyCentered() {
        let box = ViewModePlanner.cellBox(
            content: CGRect(x: 0, y: 0, width: 400, height: 500),
            cell: CGSize(width: 400, height: 600), side: .right, vAlign: .center)
        #expect(box == CGRect(x: 0, y: -50, width: 400, height: 600))
    }

    /// The vertical alignment is isolated in `CellVAlign` (OWNER-CONFIRM for
    /// SIZE-3): `.bottom` pads the top only, `.top` pads the bottom only. A short
    /// page 400×500 in a 400×600 cell:
    ///   .bottom ⇒ box.minY = content.minY = 0 ⇒ (0,0,400,600) (blank on top).
    ///   .top    ⇒ box.minY = content.maxY − cell.h = 500 − 600 = −100 ⇒
    ///             (0,−100,400,600) (blank on the bottom).
    @Test func cellVAlign_bottomAndTop_areOneLineSwitchable() {
        let content = CGRect(x: 0, y: 0, width: 400, height: 500)
        let cell = CGSize(width: 400, height: 600)
        #expect(ViewModePlanner.cellBox(content: content, cell: cell, side: .right, vAlign: .bottom)
            == CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(ViewModePlanner.cellBox(content: content, cell: cell, side: .right, vAlign: .top)
            == CGRect(x: 0, y: -100, width: 400, height: 600))
    }

    /// SIZE-5 — a small page's box is PADDED to the cell, its content NOT scaled:
    /// the box grows to the cell width but the content keeps its natural width
    /// (box width − pad == content width). content 300 wide, cell 400 wide, left
    /// slot ⇒ box (−100,0,400,600); padLeft = |box.minX| = 100; box.width − padLeft
    /// = 400 − 100 = 300 == content width (no over-zoom).
    @Test func size5_smallPage_paddedNotScaled() {
        let content = CGRect(x: 0, y: 0, width: 300, height: 600)
        let box = ViewModePlanner.cellBox(
            content: content, cell: CGSize(width: 400, height: 600),
            side: .left, vAlign: .center)
        #expect(box.width == 400)                          // cell width
        let padLeft = 0 - box.minX                         // 100
        #expect(box.width - padLeft == content.width)      // 400 − 100 == 300
    }

    // MARK: twoUpBoxOverrides — whole-document, uniform cell

    /// SIZE-3/4 — the override map groups pages into spreads and gives every cell
    /// the DOCUMENT-wide max content size, each page placed spine-ward. Four pages
    /// [300,400,300,400]×600, default pairing (0,1)(2,3), center ⇒ cell (400,600):
    ///   0 left  ⇒ (−100,0,400,600)   1 right ⇒ (0,0,400,600)
    ///   2 left  ⇒ (−100,0,400,600)   3 right ⇒ (0,0,400,600)
    @Test func size3_twoUpBoxOverrides_uniformCell_defaultPairing() {
        let contents = [
            CGRect(x: 0, y: 0, width: 300, height: 600),
            CGRect(x: 0, y: 0, width: 400, height: 600),
            CGRect(x: 0, y: 0, width: 300, height: 600),
            CGRect(x: 0, y: 0, width: 400, height: 600),
        ]
        let map = ViewModePlanner.twoUpBoxOverrides(
            pageContents: contents, layout: .default, vAlign: .center)
        #expect(map[0] == CGRect(x: -100, y: 0, width: 400, height: 600))
        #expect(map[1] == CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(map[2] == CGRect(x: -100, y: 0, width: 400, height: 600))
        #expect(map[3] == CGRect(x: 0, y: 0, width: 400, height: 600))
    }

    /// A document-wide OUTLIER (wider AND taller) sets the uniform cell for every
    /// page. Pages [(300×600),(400×600),(500×700)] ⇒ cell (500,700).
    ///   page 0 (300×600) left slot, center ⇒
    ///     box.minX = 300 − 500 = −200; padBottom = (700−600)/2 = 50 ⇒ minY = −50
    ///     ⇒ (−200,−50,500,700).
    @Test func size3_twoUpBoxOverrides_documentWideOutlierSetsCell() {
        let contents = [
            CGRect(x: 0, y: 0, width: 300, height: 600),
            CGRect(x: 0, y: 0, width: 400, height: 600),
            CGRect(x: 0, y: 0, width: 500, height: 700),
        ]
        let map = ViewModePlanner.twoUpBoxOverrides(
            pageContents: contents, layout: .default, vAlign: .center)
        #expect(map[0] == CGRect(x: -200, y: -50, width: 500, height: 700))
    }

    /// Book pairing (page 0 alone on the RIGHT) places page 0 in the RIGHT slot
    /// (content flush LEFT). displaysAsBook pairs (—,0)(1,2)…; page 0 is a lone
    /// recto ⇒ side .right. content 300×600, cell 400×600 ⇒ (0,0,400,600).
    @Test func size3_twoUpBoxOverrides_bookLayout_page0IsRightSlot() {
        let contents = [
            CGRect(x: 0, y: 0, width: 300, height: 600),
            CGRect(x: 0, y: 0, width: 400, height: 600),
            CGRect(x: 0, y: 0, width: 400, height: 600),
        ]
        let map = ViewModePlanner.twoUpBoxOverrides(
            pageContents: contents,
            layout: BookLayout(displaysAsBook: true), vAlign: .center)
        // page 0 is the lone recto on the right → flush LEFT (pads on the right).
        #expect(map[0] == CGRect(x: 0, y: 0, width: 400, height: 600))
    }

    // MARK: SIZE-1 / SIZE-2 — single-mode scale comes from the CURRENT page

    /// SIZE-1 — single fixed: the fit scale is the CURRENT page's own whole-page
    /// fit; a wider outlier page elsewhere must NOT shrink it (regression against
    /// the autoScales "fit the widest page" bug).
    /// GIVEN viewport 800×616, current page 400×600, an outlier 800×600.
    ///   current fixedFit = min((800−16)/400=1.96, (616−16)/600=1.0) = 1.0.
    ///   widest  fixedFit = min((800−16)/800=0.98, 1.0) = 0.98.
    /// THEN singlePageScale uses the current page (1.0), NOT the widest (0.98).
    @Test func size1_singleFixedScale_fromCurrentPage_notWidest() {
        let viewport = CGSize(width: 800, height: 616)
        let current = CGSize(width: 400, height: 600)
        let widest = CGSize(width: 800, height: 600)
        let scale = ViewModePlanner.singlePageScale(
            mode: .singleFixed, viewport: viewport, currentPageSize: current)
        #expect(scale == 1.0)
        #expect(scale == ViewModePlanner.fixedFitScale(
            viewport: viewport, pageSize: current, margin: ReaderLayout.margin))
        #expect(scale != ViewModePlanner.fixedFitScale(
            viewport: viewport, pageSize: widest, margin: ReaderLayout.margin))
    }

    /// SIZE-2 — single continuous: the entry scale is the CURRENT page's width
    /// fit; a wider outlier must NOT shrink it.
    /// GIVEN viewport 816×1000, current page 400×600, outlier 800×600.
    ///   current widthFit = (816−16)/400 = 2.0; widest = (816−16)/800 = 1.0.
    /// THEN singlePageScale uses the current page (2.0), NOT the widest (1.0).
    @Test func size2_singleContinuousScale_fromCurrentPage_notWidest() {
        let viewport = CGSize(width: 816, height: 1000)
        let current = CGSize(width: 400, height: 600)
        let widest = CGSize(width: 800, height: 600)
        let scale = ViewModePlanner.singlePageScale(
            mode: .singleContinuous, viewport: viewport, currentPageSize: current)
        #expect(scale == 2.0)
        #expect(scale == ViewModePlanner.widthFitScale(
            viewportWidth: viewport.width, pageWidth: current.width,
            margin: ReaderLayout.margin))
        #expect(scale != ViewModePlanner.widthFitScale(
            viewportWidth: viewport.width, pageWidth: widest.width,
            margin: ReaderLayout.margin))
    }
}
