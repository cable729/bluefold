#if os(macOS)
import AppKit
import CoreGraphics
import Dependencies
import PDFKit
import ReaderCore
import Testing
@testable import ReaderUI

/// Live-view checks for the phase-6 different-size-page machinery: `PageBoxStore`
/// applies/reverts in-memory box overrides (never the file — Calibre read-only),
/// the pure `twoUpBoxOverrides` make a mixed-size spread ABUT its central gutter,
/// and `LayoutApplier.refitSingleFixed` re-fits the current page (SIZE-1). Ties
/// the paper math (PageAlignmentTests) to PDFKit's real box behavior
/// (docs/PDFKIT-FACTS.md Fact 3).
@MainActor
@Suite(.serialized) struct PageBoxStoreTests {
    /// Round-trip — apply overrides then revert restores the ORIGINAL boxes
    /// exactly. Enlarging the boxes changes `bounds(for:)`; reverting must undo
    /// it to the byte (revert-safe teardown).
    @Test func pageBoxStore_applyThenRevert_restoresOriginalBounds() {
        let doc = PDFKitProbe.makeDocument(pageSizes: [
            CGSize(width: 300, height: 600),
            CGSize(width: 400, height: 600),
        ])
        let origMedia = (0..<2).map { doc.page(at: $0)!.bounds(for: .mediaBox) }
        let origCrop = (0..<2).map { doc.page(at: $0)!.bounds(for: .cropBox) }

        let overrides = ViewModePlanner.twoUpBoxOverrides(
            pageContents: origCrop, layout: .default, vAlign: .center)
        let store = PageBoxStore()
        store.apply(overrides: overrides, to: doc)

        // The boxes actually changed (page 0 enlarged to the 400-wide cell).
        #expect(doc.page(at: 0)!.bounds(for: .cropBox) == CGRect(x: -100, y: 0, width: 400, height: 600))
        #expect(store.isActive)

        store.revert(document: doc)
        for i in 0..<2 {
            #expect(doc.page(at: i)!.bounds(for: .mediaBox) == origMedia[i])
            #expect(doc.page(at: i)!.bounds(for: .cropBox) == origCrop[i])
        }
        #expect(!store.isActive)
    }

    /// Cover guard — an override SMALLER than the content is enlarged back up so
    /// content is never clipped (only padding is ever added). A deliberately-tiny
    /// box (100×100) on a 400×600 page must be unioned to at least contain the
    /// original content.
    @Test func pageBoxStore_neverShrinksBelowContent() {
        let doc = PDFKitProbe.makeDocument(pageSizes: [CGSize(width: 400, height: 600)])
        let content = doc.page(at: 0)!.bounds(for: .cropBox)
        let store = PageBoxStore()
        store.apply(overrides: [0: CGRect(x: 0, y: 0, width: 100, height: 100)], to: doc)
        let applied = doc.page(at: 0)!.bounds(for: .cropBox)
        #expect(applied.contains(content), "cover guard clipped content: \(applied)")
        store.revert(document: doc)
    }

    /// SIZE-3/4 (live) — a MIXED-size spread abuts the central gutter. Pages
    /// alternate 300/400 wide; after `twoUpBoxOverrides` every cell is 400 wide,
    /// so the two CONTENT edges meet with an inner gap ≈ M even though the raw
    /// pages differ. Measured by converting each page's ORIGINAL content rect
    /// (captured before the override) to view space.
    ///
    /// GIVEN 4 pages [300,400,300,400]×600, viewport 824×1000, twoUpContinuous.
    ///   cell = (400,600); twoUpWidthFit = (824−24)/(2·400) = 1.0; inset = 4.
    /// THEN rightContent.minX − leftContent.maxX ≈ ReaderLayout.margin (≤1.5pt).
    @Test func size3_live_mixedSizeSpreadAbutsGutter() {
        let sizes = [
            CGSize(width: 300, height: 600), CGSize(width: 400, height: 600),
            CGSize(width: 300, height: 600), CGSize(width: 400, height: 600),
        ]
        let doc = PDFKitProbe.makeDocument(pageSizes: sizes)
        let origContent = (0..<4).map { doc.page(at: $0)!.bounds(for: .cropBox) }

        let overrides = ViewModePlanner.twoUpBoxOverrides(
            pageContents: origContent, layout: .default, vAlign: .center)
        let store = PageBoxStore()
        store.apply(overrides: overrides, to: doc)

        let cellW = ViewModePlanner.spreadCell(contents: origContent).width
        #expect(cellW == 400)
        let scale = ViewModePlanner.twoUpWidthFitScale(
            viewportWidth: 824, pageWidth: cellW, margin: ReaderLayout.margin)
        #expect(scale == 1.0)

        let (view, _) = PDFKitProbe.makeView(
            document: doc, viewport: CGSize(width: 824, height: 1000),
            mode: .twoUpContinuous)
        let plan = LayoutPlan(
            displayMode: ViewMode.doubleContinuous.displayModeRaw,
            pageBreakMarginInset: ViewModePlanner.marginInset(
                onScreenGap: ReaderLayout.margin, scale: scale),
            scaleFactor: scale)
        let box = CapturedLogs()
        withDependencies { $0.appLogger = .captured(into: box) } operation: {
            LayoutApplier.apply(plan, to: view, log: AppLogger.captured(into: box))
        }
        PDFKitProbe.settle(6)

        // Content edges (original content rects) for the first spread (pages 0,1).
        let page0 = doc.page(at: 0)!
        let page1 = doc.page(at: 1)!
        let leftContent = view.convert(origContent[0], from: page0)
        let rightContent = view.convert(origContent[1], from: page1)
        let innerContentGap = rightContent.minX - leftContent.maxX

        // Box edges (the enlarged 400-wide cells) — both are the same width now.
        let leftBox = view.convert(page0.bounds(for: view.displayBox), from: page0)
        let rightBox = view.convert(page1.bounds(for: view.displayBox), from: page1)
        print("PROBE size3 live mixed: cellW=\(cellW) scale=\(view.scaleFactor) " +
              "leftBoxW=\(leftBox.width) rightBoxW=\(rightBox.width) " +
              "innerContentGap=\(innerContentGap) (expect ≈ \(ReaderLayout.margin))")

        #expect(abs(leftBox.width - rightBox.width) <= 1.5, "cells not uniform width")
        #expect(abs(innerContentGap - ReaderLayout.margin) <= 1.5,
                "mixed-size content did not abut the gutter: gap=\(innerContentGap)")
        store.revert(document: doc)
    }

    /// SIZE-1 (live) — single FIXED re-fits the CURRENT page on every page change:
    /// a narrow page and a wide page each get their OWN whole-page fit (the wide
    /// page is not shrunk to fit some other page, nor is the narrow page over-
    /// zoomed). GIVEN pages [400×600, 800×600] in an 800×616 single-page view:
    ///   page 0 (400×600) fit = min((800−16)/400=1.96, (616−16)/600=1.0) = 1.0.
    ///   page 1 (800×600) fit = min((800−16)/800=0.98, 1.0) = 0.98.
    @Test func size1_live_singleFixed_refitsPerCurrentPage() {
        let doc = PDFKitProbe.makeDocument(pageSizes: [
            CGSize(width: 400, height: 600),
            CGSize(width: 800, height: 600),
        ])
        let (view, _) = PDFKitProbe.makeView(
            document: doc, viewport: CGSize(width: 800, height: 616),
            mode: .singlePage)
        let box = CapturedLogs()

        view.go(to: doc.page(at: 0)!)
        PDFKitProbe.settle()
        let s0 = withDependencies({ $0.appLogger = .captured(into: box) }) {
            LayoutApplier.refitSingleFixed(view, log: AppLogger.captured(into: box))
        }
        #expect(s0 != nil)
        #expect(abs((s0 ?? 0) - 1.0) <= 1e-9)
        #expect(abs(view.scaleFactor - 1.0) <= 0.001)

        view.go(to: doc.page(at: 1)!)
        PDFKitProbe.settle()
        let s1 = withDependencies({ $0.appLogger = .captured(into: box) }) {
            LayoutApplier.refitSingleFixed(view, log: AppLogger.captured(into: box))
        }
        #expect(abs((s1 ?? 0) - 0.98) <= 1e-9)
        #expect(abs(view.scaleFactor - 0.98) <= 0.001)
        #expect(!box.messages(.layout).isEmpty, "refit did not instrument via .layout")
    }
}
#endif
