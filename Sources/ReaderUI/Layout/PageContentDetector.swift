#if os(macOS)
import CoreGraphics
import ObjectiveC
import PDFKit

/// Detects a page's printed content box — the bounding box of its ink — so
/// "trim margins" (TRIM-1..7) can crop the publisher's whitespace to a real
/// content box. This is the DETECTION core ported from the old branch's
/// `PageContentCrop` (9f863a5); Phase 7 keeps the raw-CG sampling, ink
/// threshold, and reclaim/cover guards, but exposes a PER-PAGE `contentBox`
/// (TRIM-6 crops each page to its OWN content box) and does NOT apply anything —
/// application goes through `PageBoxStore.crop` (Phase 6 store, Phase 7 crop
/// path).
///
/// Detection renders each page straight from Core Graphics (`page.pageRef`), NOT
/// through PDFKit, so the theme filter in `ThemedPDFPage.draw` never colors the
/// pixels we measure. Results are cached on the page (associated object) so a
/// whole-document sweep pays the render cost once (measured ~1.4 ms/page).
@MainActor
public enum PageContentDetector {
    /// Padding left around the detected ink, per side, in page points. The left
    /// side keeps a wider gutter so content never sits under a margin-anchor
    /// glyph (glyph at x∈[5,20] from the crop edge — see `AnchorOverlay`); the
    /// other sides trim close for a genuinely tight column.
    /// `nonisolated` (like the rest of the detection constants): the pure
    /// `computeContentBox` path runs off the main thread in `ContentBoxService`.
    public nonisolated static let leftPadding: CGFloat = 20
    public nonisolated static let rightPadding: CGFloat = 10
    public nonisolated static let verticalPadding: CGFloat = 12

    /// Target width in pixels for the detection render (cheap; content geometry
    /// doesn't need fine resolution).
    nonisolated static let renderWidth: CGFloat = 320

    /// A pixel counts as content when it's darker than this on 0...255 white.
    /// Anti-aliased text edges and faint rules still cross it; JPEG noise in
    /// scans mostly doesn't.
    nonisolated static let inkThreshold: UInt8 = 245

    /// Only trim when the padded content leaves at least this fraction of the
    /// page to reclaim — below it there's nothing to gain and we'd risk shaving
    /// real content, so the page is left exactly as the publisher set it.
    nonisolated static let minReclaimFraction: CGFloat = 0.04

    /// Cover / mis-detection guard: never accept an ink box narrower or shorter
    /// than this fraction of the page in either axis. A near-blank page, a lone
    /// folio, or a thin cover stripe would otherwise collapse the crop.
    ///
    /// NOTE: kept at the old branch's 0.4 (not the ~0.6 in the Phase-7 brief) on
    /// purpose — a 0.6 width guard would SKIP books that most need trimming
    /// (Dummit & Foote ships ~22% side margins ⇒ ~56% content width), defeating
    /// the feature on exactly its target. 0.4 rejects covers/folios while still
    /// trimming dense-margin textbooks.
    nonisolated static let minContentFraction: CGFloat = 0.4

    private static var contentBoxKey: UInt8 = 0

    /// The content box this page should be cropped TO for trim, in page (media)
    /// coordinates — the ink bounding box grown by the per-side padding and
    /// clamped to the media box. `nil` when the page should be left as-is: blank,
    /// already tight (little to reclaim), or a cover/mis-detection (ink too small
    /// in either axis). Computed once (renders the page) and cached on the page.
    public static func contentBox(of page: PDFPage) -> CGRect? {
        if let cached = cachedContentBox(of: page) { return cached.box }
        let result = computeContentBox(of: page)
        seedCache(result, on: page)
        return result
    }

    /// A cached detection result: `box == nil` means detection ran and found
    /// nothing to trim (blank / already tight / cover). Distinguishing "cached
    /// as nil" from "never detected" (below) is what lets the applier check
    /// readiness without triggering a main-thread render.
    struct Cached { let box: CGRect? }

    /// The cached detection for this page, or `nil` if it was never detected.
    static func cachedContentBox(of page: PDFPage) -> Cached? {
        guard let boxed = objc_getAssociatedObject(page, &contentBoxKey) as? NSValue
        else { return nil }
        let rect = boxed.rectValue
        return Cached(box: rect.isNull ? nil : rect)
    }

    /// Seeds the per-page cache with a pre-computed result (e.g. from the
    /// background `ContentBoxService`), so the live document's pages read the
    /// same box the preloader found WITHOUT re-rendering on the main thread.
    static func seedCache(_ box: CGRect?, on page: PDFPage) {
        objc_setAssociatedObject(
            page, &contentBoxKey, NSValue(rect: box ?? .null), .OBJC_ASSOCIATION_RETAIN)
    }

    /// Pure detection (renders the page, no caching) — safe to call OFF the main
    /// thread on a `PDFDocument` owned entirely by a background actor (the
    /// `ContentBoxService` preloader). `contentBox(of:)` wraps this with the
    /// on-page cache for the synchronous main-thread path.
    nonisolated static func computeContentBox(of page: PDFPage) -> CGRect? {
        compute(page)
    }

    nonisolated private static func compute(_ page: PDFPage) -> CGRect? {
        let media = page.bounds(for: .mediaBox)
        guard media.width > 0, media.height > 0 else { return nil }
        guard let ink = inkBox(of: page, media: media) else { return nil }

        // Cover / mis-detection guard: ink too small in either axis ⇒ skip.
        guard ink.width >= media.width * minContentFraction,
              ink.height >= media.height * minContentFraction
        else { return nil }

        let padded = CGRect(
            x: ink.minX - leftPadding,
            y: ink.minY - verticalPadding,
            width: ink.width + leftPadding + rightPadding,
            height: ink.height + 2 * verticalPadding
        ).intersection(media)

        // Nothing worth reclaiming ⇒ leave the publisher's layout untouched.
        let reclaim = 1 - (padded.width * padded.height) / (media.width * media.height)
        guard reclaim >= minReclaimFraction else { return nil }
        return padded
    }

    /// Renders one page from Core Graphics into a grayscale bitmap and returns
    /// the bounding box of its ink in page coordinates. Renders the raw page (no
    /// theme filter), on a white ground, so "not white" means content.
    nonisolated static func inkBox(of page: PDFPage, media: CGRect) -> CGRect? {
        guard let cgPage = page.pageRef, media.width > 0, media.height > 0 else { return nil }
        let scale = renderWidth / media.width
        let pxW = Int((media.width * scale).rounded())
        let pxH = Int((media.height * scale).rounded())
        guard pxW > 8, pxH > 8 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: pxW,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))

        // Map the media box onto the pixel rect (handles page rotation), clip to
        // it, and draw the raw page content.
        let pixelRect = CGRect(x: 0, y: 0, width: pxW, height: pxH)
        let transform = cgPage.getDrawingTransform(
            .mediaBox, rect: pixelRect, rotate: 0, preserveAspectRatio: true)
        ctx.saveGState()
        ctx.concatenate(transform)
        ctx.clip(to: cgPage.getBoxRect(.mediaBox))
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()

        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: pxW * pxH)

        // Buffer row 0 is the TOP of the image; CoreGraphics y is up. Scan for
        // the ink extent in pixel space, then map back to page points.
        var minCol = pxW, maxCol = -1, minRow = pxH, maxRow = -1
        for row in 0..<pxH {
            let base = row * pxW
            for col in 0..<pxW where pixels[base + col] < inkThreshold {
                if col < minCol { minCol = col }
                if col > maxCol { maxCol = col }
                if row < minRow { minRow = row }
                if row > maxRow { maxRow = row }
            }
        }
        guard maxCol >= minCol, maxRow >= minRow else { return nil }

        let sx = media.width / CGFloat(pxW)
        let sy = media.height / CGFloat(pxH)
        let minX = media.minX + CGFloat(minCol) * sx
        let maxX = media.minX + CGFloat(maxCol + 1) * sx
        // row 0 = top → highest page-y.
        let maxY = media.minY + CGFloat(pxH - minRow) * sy
        let minY = media.minY + CGFloat(pxH - maxRow - 1) * sy
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
#endif
