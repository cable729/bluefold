#if os(macOS)
import CoreGraphics
import PDFKit

/// Applies and reverts in-memory page-box overrides for two-up alignment of
/// different-size pages (SIZE-3/4). It NEVER writes the file — Calibre stays
/// read-only (CLAUDE.md); the overrides live only on the in-memory
/// `PDFDocument`'s `PDFPage` objects and are reverted on teardown.
///
/// Mechanism (docs/PDFKIT-FACTS.md Fact 3): `page.setBounds(_:for:)` with a box
/// LARGER than the content is honored — the extra area renders BLANK and the
/// content is untouched. Enlarging every two-up cell to a uniform size and
/// positioning each page's content by asymmetric padding (from
/// `ViewModePlanner.twoUpBoxOverrides`) therefore aligns mixed-size pages toward
/// the spine WITHOUT cropping and WITHOUT scaling (SIZE-5 — small pages are
/// never over-zoomed).
///
/// Cover guard: an override is unioned with the page's ORIGINAL box before it is
/// applied, so the box can only ever ENLARGE — content is never clipped even if
/// a caller passes a too-small rect.
///
/// The store keeps each page's original media + crop boxes on the FIRST apply
/// (keyed by page index) so `revert` restores them exactly; a second `apply`
/// re-positions relative to the stored originals (idempotent). One store owns
/// the overrides for one document.
@MainActor
public final class PageBoxStore {
    private struct Original {
        let media: CGRect
        let crop: CGRect
    }

    /// Page index → its boxes as they were before the first override.
    private var originals: [Int: Original] = [:]

    public init() {}

    /// True while any override is in effect (originals are held) — the applier
    /// reverts on leaving two-up / teardown only when this is set.
    public var isActive: Bool { !originals.isEmpty }

    /// Sets each listed page's media + crop box to the override rect, stashing the
    /// page's original boxes on first touch. The override is unioned with the
    /// original crop box (cover guard) so it can only enlarge. Idempotent: the
    /// stored originals are captured once, so re-applying re-positions from the
    /// true originals rather than compounding.
    public func apply(overrides: [Int: CGRect], to document: PDFDocument) {
        setBoxes(overrides, to: document, unionWithOriginalCrop: true)
    }

    /// TRIM — SHRINKS each listed page's media + crop box to the override rect
    /// (the detected content box), stashing the page's original boxes on first
    /// touch. UNLIKE `apply`, the override is NOT unioned with the original crop:
    /// trim deliberately crops the cropBox SMALLER than the publisher's page, so
    /// the enlarge-only cover guard must be bypassed. The caller is responsible
    /// for passing a box that contains the real ink (`PageContentDetector` grows
    /// the ink box by padding), so content is never clipped.
    ///
    /// Composes with the two-up enlarge path: for double + trim the caller feeds
    /// the CROPPED content boxes through `ViewModePlanner.twoUpBoxOverrides` to
    /// get uniform-cell boxes and passes THOSE here — cropping to a cell that is
    /// ≥ the content box but built from content (never the publisher's margins),
    /// so the spread still abuts the gutter. Idempotent from the true originals
    /// (captured once); `revert` restores them for BOTH paths.
    public func crop(overrides: [Int: CGRect], to document: PDFDocument) {
        setBoxes(overrides, to: document, unionWithOriginalCrop: false)
    }

    private func setBoxes(
        _ overrides: [Int: CGRect], to document: PDFDocument, unionWithOriginalCrop: Bool
    ) {
        for (index, rawBox) in overrides {
            guard let page = document.page(at: index) else { continue }
            if originals[index] == nil {
                originals[index] = Original(
                    media: page.bounds(for: .mediaBox),
                    crop: page.bounds(for: .cropBox))
            }
            let original = originals[index]!
            // Enlarge path (SIZE-3/4): cover guard — never smaller than the
            // original content (crop) box. Crop path (TRIM): set the smaller box
            // directly.
            let box = unionWithOriginalCrop ? rawBox.union(original.crop) : rawBox
            page.setBounds(box, for: .mediaBox)
            page.setBounds(box, for: .cropBox)
        }
    }

    /// Restores every overridden page's original media + crop boxes and clears
    /// the store. Safe to call when inactive (no-op) and safe to call twice.
    public func revert(document: PDFDocument) {
        for (index, original) in originals {
            guard let page = document.page(at: index) else { continue }
            page.setBounds(original.media, for: .mediaBox)
            page.setBounds(original.crop, for: .cropBox)
        }
        originals.removeAll()
    }
}
#endif
