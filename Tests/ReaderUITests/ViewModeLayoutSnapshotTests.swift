#if os(macOS)
import AppKit
import CoreGraphics
import PDFKit
import SnapshotTesting
import Testing
@testable import ReaderUI

/// Phase 9 (issue #20) — a VISUAL REGRESSION NET for the four view-mode layouts,
/// the cases where "margins look wrong": {single/double × fixed/continuous} ×
/// {normal fit, trimmed} × {uniform pages, mixed-size pages}.
///
/// ## Determinism (the hard part — read before touching)
///
/// A snapshot recorded on a 2× (Retina) Mac and re-checked on a 1× CI runner
/// MUST produce byte-identical pixels, or the reference never matches and
/// `perceptualPrecision` cannot save it (a size mismatch is rejected outright).
/// We therefore NEVER screenshot a live `PDFView`'s backing store (that carries
/// the backing-scale sub-pixel term documented in docs/PDFKIT-FACTS.md Fact 2).
///
/// Instead each reference is COMPOSED into a bitmap we own: a `CGContext` at an
/// EXPLICIT pixel size (viewport points == pixels, 1×), into which we draw each
/// visible page via `CGContext.drawPDFPage` (raw Core Graphics, exactly like
/// `PageContentDetector`). The pixel buffer is a pure function of:
///   - the REAL planner output (`ViewModePlanner.standardPlan` → scaleFactor +
///     `pageBreakMargins` inset, hence every gap = `2·inset·scale`),
///   - the REAL trim boxes (`PageContentDetector.contentBox`), and
///   - the REAL two-up alignment boxes (`ViewModePlanner.twoUpBoxOverrides`).
/// Nothing consults `NSScreen.backingScaleFactor`, so 1× and 2× yield the same
/// bytes. `LayoutSnapshotDeterminismTest` pins that (renders twice, memcmp).
///
/// This composition is NOT a pixel-perfect replica of PDFKit's live scroll
/// position (which the applier derives from live geometry and is not a pure
/// function of the plan). It is a faithful, deterministic rendering of the
/// margins/gaps/fit/crop the planner dictates — which is exactly the surface
/// that regresses when "margins look wrong", and it changes whenever the margin
/// math does (proven by the deliberate-regression check in the PR).
///
/// Serialized + no `PDFView` (pure CG) → no parallel-teardown SIGSEGV.
@MainActor
@Suite(.serialized)
struct ViewModeLayoutSnapshotTests {
    // MARK: - The matrix

    /// One representative snapshot case. `pageSet` picks uniform vs mixed-size
    /// fixtures; `variant` picks normal fit vs trimmed; `anchorIndex` is the
    /// page (single) / first page of the pair (double) the fixed modes show.
    struct Case: Sendable {
        let name: String
        let mode: ViewMode
        let pageSet: PageSet
        let variant: Variant
        let anchorIndex: Int
    }

    enum PageSet: Sendable { case uniform, mixed }
    enum Variant: Sendable { case normal, trimmed }

    /// Viewport is a round 800×1000 so points == an integral pixel count at 1×.
    nonisolated static let viewport = CGSize(width: 800, height: 1000)

    /// The full 16-case matrix (4 modes × 2 variants × 2 page sets). Mixed-size
    /// single-mode cases anchor on index 1 (the odd-size page) so the different
    /// size actually shows; everything else anchors on 0.
    nonisolated static let cases: [Case] = {
        var out: [Case] = []
        for mode in ViewMode.allCases {
            for pageSet in [PageSet.uniform, .mixed] {
                for variant in [Variant.normal, .trimmed] {
                    let anchor = (pageSet == .mixed && !mode.isTwoUp) ? 1 : 0
                    let name = [
                        modeSlug(mode),
                        pageSet == .uniform ? "uniform" : "mixed",
                        variant == .normal ? "normal" : "trimmed",
                    ].joined(separator: "_")
                    out.append(Case(
                        name: name, mode: mode, pageSet: pageSet,
                        variant: variant, anchorIndex: anchor))
                }
            }
        }
        return out
    }()

    nonisolated static func modeSlug(_ mode: ViewMode) -> String {
        switch mode {
        case .singleFixed: return "single_fixed"
        case .singleContinuous: return "single_continuous"
        case .doubleFixed: return "double_fixed"
        case .doubleContinuous: return "double_continuous"
        }
    }

    @Test(arguments: cases)
    func layout(_ testCase: Case) {
        let doc = LayoutSnapshotFixtures.document(for: testCase.pageSet)
        let image = LayoutSnapshotRenderer.render(
            document: doc, case: testCase, viewport: Self.viewport)
        assertSnapshot(
            of: image,
            as: .image(precision: 0.995, perceptualPrecision: 0.98),
            named: testCase.name,
            testName: "layout")
    }

    /// Record-mode guard. A committed `record: .all` (or a lingering
    /// `SNAPSHOT_TESTING_RECORD=all` baked into the suite) would make every
    /// `assertSnapshot` OVERWRITE its reference and pass — silently destroying
    /// the whole net. Fail loudly if record mode is on when the suite runs.
    @Test func recordModeIsOff() {
        #expect(isRecording == false, "snapshot record mode must never be committed")
    }
}

// MARK: - Determinism pin

/// Proves the composed bitmap is backing-scale-independent: render the SAME case
/// twice and require byte-identical PNG output. If this holds on any machine, a
/// 1× CI runner and a 2× dev Mac produce the same reference (we never touch the
/// screen backing store). Kept separate so a determinism break is legible even
/// if the matrix references are stale.
@MainActor
@Suite(.serialized)
struct LayoutSnapshotDeterminismTest {
    @Test func compositionIsByteStableAcrossRenders() throws {
        let testCase = ViewModeLayoutSnapshotTests.Case(
            name: "det", mode: .doubleContinuous, pageSet: .mixed,
            variant: .trimmed, anchorIndex: 0)
        let doc = LayoutSnapshotFixtures.document(for: testCase.pageSet)
        let a = LayoutSnapshotRenderer.render(
            document: doc, case: testCase, viewport: ViewModeLayoutSnapshotTests.viewport)
        let b = LayoutSnapshotRenderer.render(
            document: doc, case: testCase, viewport: ViewModeLayoutSnapshotTests.viewport)
        let pngA = try #require(a.pngDataForTest)
        let pngB = try #require(b.pngDataForTest)
        #expect(pngA == pngB, "layout composition is not deterministic across renders")
    }
}

// MARK: - Fixtures

/// Programmatic fixture PDFs: each page is a WHITE sheet with a solid BLACK
/// content rectangle inset from the edges, so (a) trim has real whitespace to
/// reclaim (`PageContentDetector` finds the inner rect) and (b) crisp fills
/// keep anti-aliasing — hence cross-machine byte drift — to a minimum.
@MainActor
enum LayoutSnapshotFixtures {
    /// Uniform: four identical 400×600 pages. Mixed: alternating sizes so both
    /// two-up cell alignment (SIZE-3/4) and single-mode per-page fit (SIZE-1/2)
    /// have something to show.
    static func document(for pageSet: ViewModeLayoutSnapshotTests.PageSet) -> PDFDocument {
        switch pageSet {
        case .uniform:
            return make(pageSizes: Array(repeating: CGSize(width: 400, height: 600), count: 4))
        case .mixed:
            return make(pageSizes: [
                CGSize(width: 400, height: 600),
                CGSize(width: 320, height: 560),
                CGSize(width: 400, height: 600),
                CGSize(width: 320, height: 560),
            ])
        }
    }

    /// Content is inset 60 pt on every side of each page — comfortably inside
    /// the detector's cover guard (content ≥ 40% of the page on both axes) while
    /// leaving a fat publisher margin for trim to reclaim.
    static let contentInset: CGFloat = 60

    static func make(pageSizes: [CGSize]) -> PDFDocument {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var firstBox = CGRect(origin: .zero, size: pageSizes[0])
        let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil)!
        for size in pageSizes {
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.setFillColor(CGColor(gray: 1, alpha: 1))   // white paper
            context.fill(box)
            let content = box.insetBy(dx: contentInset, dy: contentInset)
            context.setFillColor(CGColor(gray: 0, alpha: 1))   // black ink block
            context.fill(content)
            context.endPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }
}

// MARK: - The deterministic renderer

/// Composes a fixed-size, backing-independent bitmap of a view mode's layout
/// from REAL planner/detector/alignment output. See the suite doc comment for
/// why this is deterministic and what it does (and does not) claim to reproduce.
@MainActor
enum LayoutSnapshotRenderer {
    /// Neutral gray so page paper (white) and its margins are visible against
    /// the reader background — matters only for legibility of a diff, not for
    /// determinism.
    static let background = CGFloat(0.80)

    /// A page placed for drawing: which page, and the page-space rect (media or
    /// crop or two-up cell box) whose region maps into the on-screen cell.
    struct Cell { let page: PDFPage; let sourceBox: CGRect }

    static func render(
        document: PDFDocument, case testCase: ViewModeLayoutSnapshotTests.Case,
        viewport: CGSize
    ) -> NSImage {
        let mode = testCase.mode
        let boxes = sourceBoxes(document: document, case: testCase)
        // Fit scale + margin inset from the REAL planner. Single fits the anchor
        // page's DISPLAY box (so a trimmed page zooms bigger); double fits the
        // uniform cell (all cells equal after twoUpBoxOverrides).
        let fitBox: CGRect
        if mode.isTwoUp {
            fitBox = boxes[0] ?? document.page(at: 0)!.bounds(for: .mediaBox)
        } else {
            fitBox = boxes[testCase.anchorIndex]
                ?? document.page(at: testCase.anchorIndex)!.bounds(for: .mediaBox)
        }
        let plan = ViewModePlanner.standardPlan(
            mode: mode, viewport: viewport, pageSize: fitBox.size)
        let scale = plan.scaleFactor
        let gap = 2 * plan.pageBreakMarginInset * scale   // on-screen between-page gap

        let rows = layoutRows(document: document, case: testCase, boxes: boxes)

        return drawImage(pixelSize: viewport) { ctx in
            ctx.setFillColor(gray: background, alpha: 1)
            ctx.fill(CGRect(origin: .zero, size: viewport))
            if mode.isContinuous {
                drawContinuous(rows: rows, scale: scale, gap: gap, viewport: viewport, ctx: ctx)
            } else {
                drawFixed(row: rows.first ?? [], scale: scale, gap: gap, viewport: viewport, ctx: ctx)
            }
        }
    }

    // MARK: source boxes (REAL trim + REAL two-up alignment)

    /// Per-index page-space rect to display. Normal → the full media box.
    /// Trimmed → `PageContentDetector.contentBox` (falls back to media box if the
    /// detector declines). Two-up modes then feed those through the REAL
    /// `twoUpBoxOverrides`, so every cell is the uniform document-max box with
    /// each page's content padded spine-ward + vertically centered.
    static func sourceBoxes(
        document: PDFDocument, case testCase: ViewModeLayoutSnapshotTests.Case
    ) -> [Int: CGRect] {
        let count = document.pageCount
        var base: [CGRect] = []
        for i in 0..<count {
            let page = document.page(at: i)!
            let media = page.bounds(for: .mediaBox)
            switch testCase.variant {
            case .normal:
                base.append(media)
            case .trimmed:
                base.append(PageContentDetector.contentBox(of: page) ?? media)
            }
        }
        if testCase.mode.isTwoUp {
            let layout = ViewModePlanner.bookLayout(of: document)
            let overrides = ViewModePlanner.twoUpBoxOverrides(
                pageContents: base, layout: layout, vAlign: .center)
            var map: [Int: CGRect] = [:]
            for i in 0..<count { map[i] = overrides[i] ?? base[i] }
            return map
        } else {
            var map: [Int: CGRect] = [:]
            for i in 0..<count { map[i] = base[i] }
            return map
        }
    }

    // MARK: rows

    /// Fixed single → one cell (the anchor page). Fixed double → the anchor's
    /// book pair (LTR left, then right), skipping empty slots. Continuous single
    /// → one cell per page. Continuous double → one row per pair.
    static func layoutRows(
        document: PDFDocument, case testCase: ViewModeLayoutSnapshotTests.Case,
        boxes: [Int: CGRect]
    ) -> [[Cell]] {
        let count = document.pageCount
        func cell(_ i: Int) -> Cell? {
            guard i >= 0, i < count, let box = boxes[i], let page = document.page(at: i)
            else { return nil }
            return Cell(page: page, sourceBox: box)
        }
        let layout = ViewModePlanner.bookLayout(of: document)

        switch testCase.mode {
        case .singleFixed:
            return cell(testCase.anchorIndex).map { [[$0]] } ?? []
        case .singleContinuous:
            return (0..<count).compactMap { cell($0).map { [$0] } }
        case .doubleFixed:
            let p = ViewModePlanner.pair(containing: testCase.anchorIndex, layout: layout)
            return [[p.left, p.right].compactMap { $0.flatMap(cell) }]
        case .doubleContinuous:
            var rows: [[Cell]] = []
            var i = 0
            // Walk pairs from the row containing page 0 forward.
            var seen = Set<Int>()
            while i < count {
                let p = ViewModePlanner.pair(containing: i, layout: layout)
                let row = [p.left, p.right].compactMap { $0.flatMap(cell) }
                if let first = row.first, !seen.contains(document.index(for: first.page)) {
                    rows.append(row)
                    for c in row { seen.insert(document.index(for: c.page)) }
                }
                // Advance past this pair.
                i = (p.right ?? p.left ?? i) + 1
            }
            return rows
        }
    }

    // MARK: drawing

    /// Fixed modes: one row (1 or 2 cells) centered horizontally and vertically.
    static func drawFixed(
        row: [Cell], scale: CGFloat, gap: CGFloat, viewport: CGSize, ctx: CGContext
    ) {
        guard !row.isEmpty else { return }
        let onScreen = row.map { CGSize(width: $0.sourceBox.width * scale, height: $0.sourceBox.height * scale) }
        let totalW = onScreen.reduce(0) { $0 + $1.width } + gap * CGFloat(row.count - 1)
        let maxH = onScreen.map(\.height).max() ?? 0
        var x = (viewport.width - totalW) / 2
        let midY = viewport.height / 2
        for (cell, size) in zip(row, onScreen) {
            let dest = CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)
            drawCell(cell, into: dest, ctx: ctx)
            x += size.width + gap
        }
        _ = maxH
    }

    /// Continuous modes: stack rows from the top, first row's top edge one margin
    /// (`ReaderLayout.margin`) below the viewport top, `gap` between rows; each
    /// row centered horizontally. Stops once a row falls below the viewport.
    static func drawContinuous(
        rows: [[Cell]], scale: CGFloat, gap: CGFloat, viewport: CGSize, ctx: CGContext
    ) {
        let margin = ReaderLayout.margin
        var topY = viewport.height - margin        // CG y of the current row's top edge
        for row in rows {
            guard !row.isEmpty else { continue }
            let onScreen = row.map { CGSize(width: $0.sourceBox.width * scale, height: $0.sourceBox.height * scale) }
            let rowH = onScreen.map(\.height).max() ?? 0
            let rowW = onScreen.reduce(0) { $0 + $1.width } + gap * CGFloat(row.count - 1)
            var x = (viewport.width - rowW) / 2
            for (cell, size) in zip(row, onScreen) {
                // Bottom-align cells within the row (spread rows are single-height).
                let dest = CGRect(x: x, y: topY - size.height, width: size.width, height: size.height)
                drawCell(cell, into: dest, ctx: ctx)
                x += size.width + gap
            }
            topY -= rowH + gap
            if topY < 0 { break }                  // nothing more is visible
        }
    }

    /// Draws one cell: paint the paper white, clip to the destination, then map
    /// the page's `sourceBox` region onto it via raw `drawPDFPage`. Anything in
    /// the source box that lies OUTSIDE the page's real content (two-up padding)
    /// renders as the white paper we just painted — the intended blank pad.
    static func drawCell(_ cell: Cell, into dest: CGRect, ctx: CGContext) {
        guard let cgPage = cell.page.pageRef, cell.sourceBox.width > 0, cell.sourceBox.height > 0
        else { return }
        ctx.saveGState()
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(dest)
        ctx.clip(to: dest)
        // Map sourceBox (page space) → dest (pixel space), y-up throughout.
        let sx = dest.width / cell.sourceBox.width
        let sy = dest.height / cell.sourceBox.height
        ctx.translateBy(x: dest.minX, y: dest.minY)
        ctx.scaleBy(x: sx, y: sy)
        ctx.translateBy(x: -cell.sourceBox.minX, y: -cell.sourceBox.minY)
        ctx.clip(to: cell.sourceBox)
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()
    }

    /// Allocates a bitmap at an EXPLICIT pixel size (points == pixels, 1×) and
    /// wraps the drawn CGImage in an NSImage sized to match, so the snapshot
    /// strategy compares our exact pixels regardless of screen backing scale.
    static func drawImage(pixelSize: CGSize, _ body: (CGContext) -> Void) -> NSImage {
        let w = Int(pixelSize.width.rounded())
        let h = Int(pixelSize.height.rounded())
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        body(ctx)
        let cg = ctx.makeImage()!
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }
}

extension NSImage {
    /// Deterministic PNG bytes for the determinism pin (bypasses screen scale by
    /// going straight through the single CGImage rep).
    var pngDataForTest: Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
