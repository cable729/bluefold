import Foundation
import os
import PDFKit
import ReaderCore

/// Semantic theme colors. Sepia is the "Claude tan" reading palette.
/// Cross-platform: the page-content theming below works identically on
/// macOS and iOS (blend modes in `draw(with:to:)`; CALayer.filters does not
/// exist on iOS). The platform theme managers own chrome and persistence.
public enum Theme {
    /// Warm paper tone multiplied onto PDF pages in sepia mode (#F5EDE1).
    public static let sepiaPaper = CGColor(red: 0.961, green: 0.929, blue: 0.882, alpha: 1)
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

        context.saveGState()
        switch filter {
        case .invert:
            context.setBlendMode(.difference)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
        case .warmPaper:
            context.setBlendMode(.multiply)
            context.setFillColor(Theme.sepiaPaper)
        case .none:
            break
        }
        // Fill the CLIP, not bounds(for: box): the blend must cover exactly
        // what this pass drew. Scans whose crop box has a non-zero origin
        // (Munkres: crop starts at 144,110 inside the media box) put
        // bounds(for:) in the wrong place for PDFKit's tile contexts,
        // leaving untinted white patches across the page.
        context.fill(context.boundingBoxOfClipPath)
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
