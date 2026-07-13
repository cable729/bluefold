import Foundation
import ObjectiveC
import os
import PDFKit
import ReaderCore

private extension PageTint {
    /// Opaque CGColor for this tint (page tiles render in sRGB).
    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: 1)
    }
}

/// The page render filter, readable from ANY thread — PDFKit draws page
/// tiles off the main thread, so this must not live on a MainActor type.
/// Written by the platform theme manager whenever the resolved theme changes.
public enum PageFilterStore {
    private static let lock = OSAllocatedUnfairLock(initialState: PageRenderFilter.none)

    public static var current: PageRenderFilter {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

/// Every page of every document the provider loads is this class
/// (via PDFDocumentDelegate.classForPage), so themes apply to page CONTENT:
/// sepia multiplies warm paper onto white; dark difference-inverts.
/// The same blend-mode approach works on iOS, unlike CALayer.filters.
final class ThemedPDFPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)

        let filter = PageFilterStore.current
        guard filter != .none else { return }

        // Fill the CLIP, not bounds(for: box): the blend must cover exactly
        // what this pass drew. Scans whose crop box has a non-zero origin
        // (Munkres: crop starts at 144,110 inside the media box) put
        // bounds(for:) in the wrong place for PDFKit's tile contexts,
        // leaving untinted white patches across the page.
        let clip = context.boundingBoxOfClipPath

        context.saveGState()
        switch filter {
        case .none:
            break
        case .multiply(let tint):
            // White paper takes the tint; black ink stays black.
            context.setBlendMode(.multiply)
            context.setFillColor(tint.cgColor)
            context.fill(clip)
        case .invert:
            context.setBlendMode(.difference)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(clip)
        case .invertTinted(let tint):
            // Two passes: invert (white→black, black→white), then screen the
            // tint to lift the now-black background up to the tint color while
            // leaving inverted-white text near-white — tinted-dark paper.
            context.setBlendMode(.difference)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(clip)
            context.setBlendMode(.screen)
            context.setFillColor(tint.cgColor)
            context.fill(clip)
        }
        context.restoreGState()
    }
}

/// PDFDocumentDelegate hook that swaps in ThemedPDFPage. PDFDocument holds
/// its delegate weakly, so callers retain this. Install it on every document
/// BEFORE any page materializes (DocumentProvider does this).
public final class PageClassProvider: NSObject, PDFDocumentDelegate {
    // Stateless; safe to share across isolation domains.
    public nonisolated(unsafe) static let shared = PageClassProvider()

    public func classForPage() -> AnyClass {
        ThemedPDFPage.self
    }
}

/// Recolors a PDF's OWN link-annotation borders — the colored boxes hyperref
/// draws around cross-references (`1.21)`, `II.4.14`, …) — to the active
/// theme's secondary (`DesignPalette.linkBox`), so they harmonize with the
/// reading surface instead of clashing (owner request: e.g. tan on Bluefold,
/// pink on Dracula).
///
/// Idempotent per color via an associated marker on the document: a plain tab
/// switch (same theme → same color) skips the walk; a theme change assigns a
/// new color and triggers exactly one walk of the displayed document. Only
/// annotations that ALREADY draw a border are touched — borderless links stay
/// invisible; we never add boxes an author omitted. Call on the main actor
/// right after assigning the document, before the view renders.
@MainActor
public enum LinkBoxColorizer {
    private static var markerKey: UInt8 = 0

    public static func apply(_ color: PlatformColor, to document: PDFDocument) {
        let key = colorKey(color)
        if objc_getAssociatedObject(document, &markerKey) as? String == key { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Link" {
                guard (annotation.border?.lineWidth ?? 0) > 0 else { continue }
                annotation.color = color
            }
        }
        objc_setAssociatedObject(document, &markerKey, key, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Stable sRGB identity so re-applying the same color no-ops.
    private static func colorKey(_ color: PlatformColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return "\(r)-\(g)-\(b)-\(a)"
    }
}
