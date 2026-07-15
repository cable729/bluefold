#if os(macOS)
import AppKit
import CoreGraphics
import Dependencies
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

/// #59 bug 5 — single-continuous trim must preserve the SEMANTIC reading
/// position (which page, and how far into it), not the raw clip-origin.y.
/// Cropping shortens every page, so a preserved raw y lands on a LATER page;
/// `LayoutApplier.capturePagePosition` + `reanchor` keep the same page's
/// same fraction at the viewport top.
@MainActor
@Suite(.serialized) struct SemanticScrollTests {

    /// The page index whose content sits at the viewport top, and the fraction
    /// of that page scrolled past — measured from live documentView geometry,
    /// independent of PDFKit's `currentPage`.
    private func pageAtViewportTop(_ view: PDFView) -> (index: Int, fraction: CGFloat)? {
        guard
            let document = view.document,
            let clip = PDFKitProbe.scrollView(in: view)?.contentView,
            let docView = clip.documentView
        else { return nil }
        let viewportTopDoc = clip.bounds.origin.y + clip.bounds.height
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let rectDoc = docView.convert(
                view.convert(page.bounds(for: view.displayBox), from: page), from: view)
            if rectDoc.minY - 0.5 <= viewportTopDoc, viewportTopDoc <= rectDoc.maxY + 0.5 {
                return (i, (rectDoc.maxY - viewportTopDoc) / rectDoc.height)
            }
        }
        return nil
    }

    /// GIVEN a 12-page book in single-continuous, parked a few pages in.
    /// WHEN trim crops every page (heights shrink) and the plan is re-applied
    ///      with the captured `PagePosition`.
    /// THEN the SAME page stays at the viewport top (raw-y preservation would
    ///      have jumped to a later page).
    @Test func trimPreservesPageNotRawY() throws {
        let size = CGSize(width: 480, height: 640)
        let doc = try makeMarginPDF(pages: 12, size: size, margin: 90)
        let vp = CGSize(width: 800, height: 700)
        let (view, window) = PDFKitProbe.makeView(
            document: doc, viewport: vp, mode: .singlePageContinuous)
        defer { PDFKitProbe.teardown(view, window) }
        let box = CapturedLogs()

        let full = ViewModePlanner.standardPlan(
            mode: .singleContinuous, viewport: vp, pageSize: size)
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.apply(full, to: view, log: AppLogger.captured(into: box))
        }
        PDFKitProbe.settle(6)

        // Park the viewport top partway into page ~5.
        let clip = try #require(PDFKitProbe.scrollView(in: view)?.contentView)
        let docView = try #require(clip.documentView)
        let page5 = try #require(doc.page(at: 5))
        let rect5 = docView.convert(
            view.convert(page5.bounds(for: view.displayBox), from: page5), from: view)
        // viewportTopDoc at 40% down page 5 → origin.y = viewportTopDoc − clipH.
        let targetTopDoc = rect5.maxY - 0.4 * rect5.height
        clip.setBoundsOrigin(CGPoint(x: clip.bounds.origin.x, y: targetTopDoc - clip.bounds.height))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        PDFKitProbe.settle(2)

        let before = try #require(pageAtViewportTop(view))
        let position = try #require(LayoutApplier.capturePagePosition(in: view))
        let rawYBefore = clip.bounds.origin.y

        // Trim: crop every page, then RE-ANCHOR (no rescale — continuous trim is
        // orthogonal to zoom). The scale must not change; the same content stays
        // under the viewport top.
        let store = PageBoxStore()
        let scale0 = view.scaleFactor
        var overrides: [Int: CGRect] = [:]
        for i in 0..<doc.pageCount {
            if let c = PageContentDetector.contentBox(of: doc.page(at: i)!) { overrides[i] = c }
        }
        #expect(!overrides.isEmpty)
        store.crop(overrides: overrides, to: doc)
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.reanchor(to: position, in: view, log: AppLogger.captured(into: box))
        }
        PDFKitProbe.settle(6)
        #expect(view.scaleFactor == scale0, "continuous trim changed zoom")

        let after = try #require(pageAtViewportTop(view))
        print("PROBE bug5: before=\(before) after=\(after) rawYBefore=\(rawYBefore) " +
              "y_p=\(position.pagePointY)")
        #expect(after.index == before.index,
                "semantic restore drifted page: \(before.index) → \(after.index)")
        // (The box-relative fraction shifts because the crop shrinks the page box;
        // content-coordinate preservation is asserted in TrimMarginsTests.trim2.)

        // Reproduction guard: raw-y preservation WOULD have drifted to a
        // DIFFERENT page (cropping repacks every page, so the old absolute y maps
        // elsewhere) — that is the bug the semantic restore fixes.
        let rawYPage = pageIndexForRawY(rawYBefore, view: view)
        #expect(rawYPage != before.index,
                "expected raw-y to drift off the page (bug), stayed on \(rawYPage)")
        store.revert(document: doc)
    }

    /// Which page a raw preserved clip-origin.y would land at the viewport top
    /// under the CURRENT (cropped) geometry — used only to demonstrate the bug.
    private func pageIndexForRawY(_ y: CGFloat, view: PDFView) -> Int {
        guard
            let document = view.document,
            let clip = PDFKitProbe.scrollView(in: view)?.contentView,
            let docView = clip.documentView
        else { return -1 }
        let viewportTopDoc = y + clip.bounds.height
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let rectDoc = docView.convert(
                view.convert(page.bounds(for: view.displayBox), from: page), from: view)
            if rectDoc.minY - 0.5 <= viewportTopDoc, viewportTopDoc <= rectDoc.maxY + 0.5 {
                return i
            }
        }
        return document.pageCount - 1
    }
}
#endif
