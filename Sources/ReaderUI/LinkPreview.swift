import CoreGraphics
import PDFKit

/// Shared setup for the live link-preview (Zotero-style peek): a real `PDFView`
/// scrolled to a link's destination, shown at the book's own on-screen scale so
/// the text is readable without zooming, auto-cropped to the page's text column
/// (the empty left/right margins fall outside the panel), and freely scrollable.
///
/// A live `PDFView` — rather than a cropped image — means the preview reads at
/// book size, scrolls in every direction, and spans page boundaries naturally
/// (a target whose content runs onto the next page just keeps going).
///
/// Same-document links only: `configure` returns nil for remote targets, whose
/// destination lives in a different file we don't open for the preview.
public enum LinkPreview {
    /// Page points of context kept ABOVE the destination so the target isn't
    /// flush against the panel's top edge (a little more than a single line).
    public static let headroom: CGFloat = 46

    /// The bounding box of all text on `page`, in page space — used to crop the
    /// preview horizontally to the text column (dropping the page margins), the
    /// way Zotero trims a reference preview. Nil when the page has no text layer
    /// (scans), so callers fall back to the full crop box.
    public static func textColumnBounds(on page: PDFPage) -> CGRect? {
        let crop = page.bounds(for: .cropBox)
        guard let selection = page.selection(for: crop) else { return nil }
        let bounds = selection.bounds(for: page).intersection(crop)
        guard !bounds.isNull, bounds.width > 1, bounds.height > 1 else { return nil }
        return bounds
    }

    /// The page-space point to scroll the preview's top-left to: the text
    /// column's left edge (crops the left margin) and `headroom` above the
    /// destination (clamped into the crop box). A page-level link (no point)
    /// anchors at the page top.
    public static func initialScrollPoint(
        destinationPoint: CGPoint?, columnBounds: CGRect?, crop: CGRect
    ) -> CGPoint {
        let x = columnBounds?.minX ?? crop.minX
        let baseY = destinationPoint?.y ?? crop.maxY
        return CGPoint(x: x, y: min(crop.maxY, baseY + headroom))
    }

    /// The on-screen panel/card size. Width tracks the text column at book
    /// scale (so both margins are cropped) but is capped at `maxWidth` — a
    /// wider column then scrolls horizontally. Height is the available cap;
    /// the content scrolls vertically within it.
    public static func panelSize(
        columnWidth: CGFloat, contentScale: CGFloat,
        maxWidth: CGFloat, maxHeight: CGFloat, horizontalInset: CGFloat
    ) -> CGSize {
        let ideal = columnWidth * contentScale + horizontalInset * 2
        return CGSize(
            width: min(max(ideal, 160), maxWidth),
            height: max(maxHeight, 160)
        )
    }

    /// Loads `target`'s destination into a fresh preview `PDFView` at
    /// `contentScale` (the source book's on-screen scale) and returns the text
    /// column width in page points for sizing, or nil if not previewable.
    /// The initial scroll is (re)applied by `scroll(_:to:in:)` once the view has
    /// a frame — `go(to:)` on an unsized view doesn't land.
    @MainActor
    @discardableResult
    public static func configure(
        _ pdfView: PDFView, document: PDFDocument, target: LinkTarget,
        contentScale: CGFloat
    ) -> CGFloat? {
        guard target.remoteFileURL == nil else { return nil }
        let index = min(max(target.entry.pageIndex, 0), max(0, document.pageCount - 1))
        guard let page = document.page(at: index) else { return nil }
        pdfView.document = document
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = false
        pdfView.scaleFactor = contentScale
        return textColumnBounds(on: page)?.width ?? page.bounds(for: .cropBox).width
    }

    /// Scrolls `pdfView` so `target`'s destination sits near the top-left with
    /// headroom and the left margin cropped. Call after the view is sized.
    @MainActor
    public static func scroll(
        _ pdfView: PDFView, to target: LinkTarget, in document: PDFDocument
    ) {
        let index = min(max(target.entry.pageIndex, 0), max(0, document.pageCount - 1))
        guard let page = document.page(at: index) else { return }
        let crop = page.bounds(for: .cropBox)
        let point = initialScrollPoint(
            destinationPoint: target.entry.point,
            columnBounds: textColumnBounds(on: page),
            crop: crop
        )
        pdfView.go(to: PDFDestination(page: page, at: point))
    }
}
