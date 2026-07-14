#if os(macOS)
import AppKit
import CoreGraphics
import Dependencies
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

/// Phase 7 — trim margins as a REAL crop (TRIM-1..7). Trim crops each page's
/// cropBox to its detected content box; the SAME planner/applier then recomputes
/// the current mode's standard plan from the CROPPED page sizes (orthogonal to
/// zoom). These tests pin the numbers: the pure fit math on cropped sizes, the
/// `PageBoxStore` crop path, and the live scroll-preservation on toggle.
@MainActor
@Suite(.serialized) struct TrimMarginsTests {

    // MARK: Pure fit math on cropped sizes (TRIM-1..4, TRIM-6)

    /// TRIM-2 — single continuous: width-fit is recomputed from the CROPPED
    /// content width, so the content fills the viewport width leaving M.
    /// GIVEN page 400 wide, content 300 wide, viewport 800, M 8.
    /// THEN scale == (800 − 2·8) / 300.
    @Test func trim2_singleContinuous_widthFitFromCroppedContent() {
        let scale = ViewModePlanner.widthFitScale(
            viewportWidth: 800, pageWidth: 300, margin: ReaderLayout.margin)
        #expect(abs(scale - (800 - 16) / 300) <= 1e-9)
        // And it is strictly larger than the uncropped page's width-fit.
        let uncropped = ViewModePlanner.widthFitScale(
            viewportWidth: 800, pageWidth: 400, margin: ReaderLayout.margin)
        #expect(scale > uncropped)
    }

    /// TRIM-4 — double continuous: the two-up width-fit is recomputed from the
    /// CROPPED content width. GIVEN content 300 wide, viewport 824, M 8.
    /// THEN scale == (824 − 3·8) / (2·300).
    @Test func trim4_doubleContinuous_twoUpWidthFitFromCropped() {
        let scale = ViewModePlanner.twoUpWidthFitScale(
            viewportWidth: 824, pageWidth: 300, margin: ReaderLayout.margin)
        #expect(abs(scale - (824 - 24) / 600) <= 1e-9)
    }

    /// TRIM-1 — single fixed: whole-page fit recomputed from the CROPPED page.
    /// GIVEN cropped page 330×484, viewport 400×800, M 8.
    /// THEN scale == min((400−16)/330, (800−16)/484) == (400−16)/330 (width binds).
    @Test func trim1_singleFixed_refitFromCroppedSize() {
        let scale = ViewModePlanner.fixedFitScale(
            viewport: CGSize(width: 400, height: 800),
            pageSize: CGSize(width: 330, height: 484), margin: ReaderLayout.margin)
        #expect(abs(scale - (400 - 16) / 330) <= 1e-9)
    }

    /// TRIM-3 — double fixed: the spread standard is recomputed from cropped
    /// sizes. GIVEN cropped page 330×484, viewport 824×1000, M 8.
    /// THEN scale == min((824−24)/(2·330), (1000−16)/484).
    @Test func trim3_doubleFixed_refitSpreadFromCropped() {
        let scale = ViewModePlanner.twoUpFixedFitScale(
            viewport: CGSize(width: 824, height: 1000),
            pageSize: CGSize(width: 330, height: 484), margin: ReaderLayout.margin)
        let widthBound: CGFloat = (824 - 24) / (2 * 330)
        let heightBound: CGFloat = (1000 - 16) / 484
        #expect(abs(scale - min(widthBound, heightBound)) <= 1e-9)
    }

    /// TRIM-6 — mixed sizes: the CROPPED content boxes feed `twoUpBoxOverrides`
    /// so every cell is the document-wide max CROPPED size (Phase-6 composition
    /// on cropped boxes, not raw pages). GIVEN cropped contents 300×480 and
    /// 260×500. THEN the uniform cell is (300, 500) and each page's cell box is
    /// that size, content placed spine-ward.
    @Test func trim6_mixedSizes_croppedBoxesFeedCells() {
        let cropped = [
            CGRect(x: 40, y: 30, width: 300, height: 480),
            CGRect(x: 50, y: 20, width: 260, height: 500),
        ]
        let cell = ViewModePlanner.spreadCell(contents: cropped)
        #expect(cell == CGSize(width: 300, height: 500))
        let overrides = ViewModePlanner.twoUpBoxOverrides(
            pageContents: cropped, layout: .default, vAlign: .center)
        // Page 0 is the left slot (spine right): content flush right.
        let box0 = try! #require(overrides[0])
        #expect(box0.size == cell)
        #expect(abs(box0.maxX - cropped[0].maxX) <= 1e-9)  // content flush right
        // Page 1 is the right slot (spine left): content flush left.
        let box1 = try! #require(overrides[1])
        #expect(box1.size == cell)
        #expect(abs(box1.minX - cropped[1].minX) <= 1e-9)  // content flush left
    }

    /// TRIM-7 — responsiveness: whole-document detection is a ONE-TIME cost
    /// (measured ~1.4 ms/page: 593-page Active Calculus detected in 0.857 s),
    /// because each page's content box is CACHED on first detection. The cache
    /// is keyed on the page and captured from the ORIGINAL geometry, so a later
    /// crop of the cropBox does NOT change (or re-trigger) detection — a full
    /// re-sweep after cropping returns the identical boxes for free. That
    /// "detect once" guarantee is what lets the current page crop synchronously
    /// while the rest stay cheap.
    @Test func trim7_wholeDocDetectionIsCachedOncePerPage() throws {
        let size = CGSize(width: 480, height: 640)
        let doc = try makeMarginPDF(pages: 10, size: size, margin: 90)
        // First sweep populates the cache.
        let first = (0..<doc.pageCount).map { PageContentDetector.contentBox(of: doc.page(at: $0)!) }
        #expect(first.allSatisfy { $0 != nil })

        // Crop every page (mutates the cropBox/mediaBox) — detection must NOT
        // re-run against the now-cropped geometry; it returns the cached box.
        let store = PageBoxStore()
        var overrides: [Int: CGRect] = [:]
        for i in 0..<doc.pageCount { overrides[i] = first[i]! }
        store.crop(overrides: overrides, to: doc)

        let second = (0..<doc.pageCount).map { PageContentDetector.contentBox(of: doc.page(at: $0)!) }
        #expect(second == first, "detection was not cached: re-ran on cropped geometry")
        store.revert(document: doc)
    }

    // MARK: PageBoxStore crop (shrink) path

    /// The crop path SHRINKS the cropBox to a smaller rect (unlike the enlarge
    /// path, which unions with the original) and `revert` restores the true
    /// original for BOTH. GIVEN a 480×640 page cropped to a 330×484 content box.
    @Test func pageBoxStore_crop_shrinksThenRevertRestores() {
        let doc = PDFKitProbe.makeDocument(pageSizes: [CGSize(width: 480, height: 640)])
        let page = doc.page(at: 0)!
        let origCrop = page.bounds(for: .cropBox)
        let origMedia = page.bounds(for: .mediaBox)
        #expect(origCrop == CGRect(x: 0, y: 0, width: 480, height: 640))

        let store = PageBoxStore()
        let content = CGRect(x: 70, y: 78, width: 330, height: 484)
        store.crop(overrides: [0: content], to: doc)

        // The cropBox actually SHRANK to the content box (no cover-guard union).
        #expect(page.bounds(for: .cropBox) == content)
        #expect(page.bounds(for: .cropBox).width < origCrop.width)
        #expect(store.isActive)

        store.revert(document: doc)
        #expect(page.bounds(for: .cropBox) == origCrop)
        #expect(page.bounds(for: .mediaBox) == origMedia)
        #expect(!store.isActive)
    }

    // MARK: Live integration (PDFKitProbe) — TRIM-1/2/5

    /// TRIM-2 (live) — single continuous: setting a known y-scroll, then trimming
    /// (crop every page to its content box + re-apply width-fit from the cropped
    /// size) must LEAVE the y-scroll unchanged and INCREASE the scale (the
    /// content now fills the viewport width).
    @Test func trim2_live_continuousPreservesYAndScalesUp() throws {
        let size = CGSize(width: 480, height: 640)
        let doc = try makeMarginPDF(pages: 12, size: size, margin: 90)
        let vp = CGSize(width: 800, height: 1000)
        let (view, window) = PDFKitProbe.makeView(
            document: doc, viewport: vp, mode: .singlePageContinuous)
        // Detach + drain before the offscreen view/window deallocate: mutating
        // page boxes schedules a PDFKit async `layoutDocumentView`; letting it
        // fire after teardown segfaults. Keep `window` alive to scope end.
        defer { view.document = nil; PDFKitProbe.settle(2); _ = window }
        let box = CapturedLogs()

        // Standard single-continuous fit on the FULL page first.
        let full = ViewModePlanner.standardPlan(
            mode: .singleContinuous, viewport: vp, pageSize: size)
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.apply(full, to: view, log: AppLogger.captured(into: box))
        }
        PDFKitProbe.settle(6)

        // Park the reading position at a known y (page points).
        let clip = try #require(PDFKitProbe.scrollView(in: view)?.contentView)
        clip.setBoundsOrigin(CGPoint(x: clip.bounds.origin.x, y: 1500))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        PDFKitProbe.settle(2)
        let y0 = clip.bounds.origin.y
        let scale0 = view.scaleFactor

        // Detect + crop EVERY page, then re-apply width-fit from the cropped
        // page size, preserving the vertical scroll (Phase-3 mechanism).
        let store = PageBoxStore()
        var overrides: [Int: CGRect] = [:]
        for i in 0..<doc.pageCount {
            if let c = PageContentDetector.contentBox(of: doc.page(at: i)!) { overrides[i] = c }
        }
        #expect(!overrides.isEmpty, "detector found nothing to trim")
        store.crop(overrides: overrides, to: doc)
        let croppedSize = doc.page(at: 0)!.bounds(for: view.displayBox).size
        let trimmed = ViewModePlanner.standardPlan(
            mode: .singleContinuous, viewport: vp, pageSize: croppedSize)
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.apply(
                trimmed, to: view, log: AppLogger.captured(into: box),
                preserveVerticalScroll: true)
        }
        PDFKitProbe.settle(6)

        let y1 = clip.bounds.origin.y
        let scale1 = view.scaleFactor
        print("PROBE trim2 live: y0=\(y0) y1=\(y1) scale0=\(scale0) scale1=\(scale1) " +
              "croppedW=\(croppedSize.width)")
        #expect(abs(y1 - y0) <= 1.5, "trim moved the y-scroll: \(y0) → \(y1)")
        #expect(scale1 > scale0 + 0.01, "trim did not scale up: \(scale0) → \(scale1)")
        store.revert(document: doc)
    }

    /// TRIM-5 (live) — round trip: trim then untrim returns the page to its
    /// ORIGINAL cropBox, scale, and y-scroll. Single fixed.
    @Test func trim5_live_roundTripRestoresLayout() throws {
        let size = CGSize(width: 480, height: 640)
        let doc = try makeMarginPDF(pages: 8, size: size, margin: 90)
        let vp = CGSize(width: 400, height: 800)
        let (view, window) = PDFKitProbe.makeView(
            document: doc, viewport: vp, mode: .singlePage)
        defer { view.document = nil; PDFKitProbe.settle(2); _ = window }
        let box = CapturedLogs()

        view.go(to: doc.page(at: 2)!)
        let plan = ViewModePlanner.standardPlan(
            mode: .singleFixed, viewport: vp, pageSize: size)
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.apply(plan, to: view, log: AppLogger.captured(into: box))
        }
        PDFKitProbe.settle(6)
        let origCrop = doc.page(at: 2)!.bounds(for: .cropBox)
        let scale0 = view.scaleFactor

        // Trim: crop + refit from cropped size.
        let store = PageBoxStore()
        var overrides: [Int: CGRect] = [:]
        for i in 0..<doc.pageCount {
            if let c = PageContentDetector.contentBox(of: doc.page(at: i)!) { overrides[i] = c }
        }
        store.crop(overrides: overrides, to: doc)
        let croppedSize = doc.page(at: 2)!.bounds(for: view.displayBox).size
        let trimmedPlan = ViewModePlanner.standardPlan(
            mode: .singleFixed, viewport: vp, pageSize: croppedSize)
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.apply(trimmedPlan, to: view, log: AppLogger.captured(into: box))
        }
        PDFKitProbe.settle(6)
        #expect(view.scaleFactor > scale0 + 0.01, "trim did not change fixed scale")

        // Untrim: revert crops + re-fit from the ORIGINAL size.
        store.revert(document: doc)
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.apply(plan, to: view, log: AppLogger.captured(into: box))
        }
        PDFKitProbe.settle(6)

        #expect(doc.page(at: 2)!.bounds(for: .cropBox) == origCrop, "cropBox not restored")
        #expect(abs(view.scaleFactor - scale0) <= 0.001, "scale not restored")
    }

    /// TRIM-1 (live) — single fixed: after trimming, the whole-page fit of the
    /// CROPPED page leaves M on the constraining axis. GIVEN a 480×640 page with
    /// 90pt margins → content ~330 wide, viewport 400×800 (width binds), M 8.
    /// THEN the cropped page's on-screen left/right margin ≈ M.
    @Test func trim1_live_fixedRefitLeavesMargin() throws {
        let size = CGSize(width: 480, height: 640)
        let doc = try makeMarginPDF(pages: 6, size: size, margin: 90)
        let vp = CGSize(width: 400, height: 800)
        let (view, window) = PDFKitProbe.makeView(
            document: doc, viewport: vp, mode: .singlePage)
        defer { view.document = nil; PDFKitProbe.settle(2); _ = window }
        let box = CapturedLogs()

        view.go(to: doc.page(at: 1)!)
        let store = PageBoxStore()
        let content = try #require(PageContentDetector.contentBox(of: doc.page(at: 1)!))
        store.crop(overrides: [1: content], to: doc)

        let croppedSize = doc.page(at: 1)!.bounds(for: view.displayBox).size
        let plan = ViewModePlanner.standardPlan(
            mode: .singleFixed, viewport: vp, pageSize: croppedSize)
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.apply(plan, to: view, log: AppLogger.captured(into: box))
        }
        PDFKitProbe.settle(6)

        // The cropped page box, in view points. Width binds, so left/right ≈ M.
        let page = doc.page(at: 1)!
        let boxView = view.convert(page.bounds(for: view.displayBox), from: page)
        let leftMargin = boxView.minX
        let rightMargin = vp.width - boxView.maxX
        print("PROBE trim1 live: croppedW=\(croppedSize.width) scale=\(view.scaleFactor) " +
              "boxView=\(boxView) left=\(leftMargin) right=\(rightMargin)")
        #expect(abs(leftMargin - ReaderLayout.margin) <= 1.5, "left margin ≠ M: \(leftMargin)")
        #expect(abs(rightMargin - ReaderLayout.margin) <= 1.5, "right margin ≠ M: \(rightMargin)")
        store.revert(document: doc)
    }
}
#endif
