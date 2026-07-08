#if os(macOS)
import AppKit
import PDFKit
import ReaderCore

/// PDFView subclass that intercepts clicks on link annotations.
///
/// PDFKit's `PDFViewDelegate.pdfViewWillClick(onLink:with:)` fires only for
/// URL actions — internal GoTo links never reach it — so link handling that
/// wants history pushes and ⌘-click-to-new-tab must intercept `mouseDown`.
/// External URL links are left to PDFView's default handling.
final class ReaderPDFView: PDFView {
    /// Called for clicks on internal links (same document or another PDF).
    /// `current` is the position before the jump — the history push target.
    /// The handler performs the navigation; the click is swallowed.
    var onLinkActivated: ((_ target: LinkTarget, _ current: NavEntry, _ inNewTab: Bool) -> Void)?

    /// Left/right arrows page-turn in every display mode. PDFView pages on
    /// arrows in single-page mode but scrolls (or beeps) in the continuous
    /// modes; intercepting here makes the behavior uniform, matching Preview.
    /// Only bare arrows are taken — modified arrows (⇧ selection, ⌘ etc.)
    /// keep PDFView's behavior, and text fields are their own responder so
    /// typing is unaffected.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty,
           let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            switch Int(scalar.value) {
            case NSRightArrowFunctionKey:
                if canGoToNextPage { goToNextPage(nil) }
                return  // consume even at the last page (no beep/side-scroll)
            case NSLeftArrowFunctionKey:
                if canGoToPreviousPage { goToPreviousPage(nil) }
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let target = linkTarget(atViewPoint: viewPoint), let onLinkActivated {
            let inNewTab = event.modifierFlags.contains(.command)
            onLinkActivated(target, currentNavEntry(), inNewTab)
            return
        }
        super.mouseDown(with: event)
    }

    private func linkTarget(atViewPoint viewPoint: CGPoint) -> LinkTarget? {
        guard
            let page = page(for: viewPoint, nearest: false),
            let annotation = page.annotation(at: convert(viewPoint, to: page)),
            let document
        else { return nil }
        return Self.resolveTarget(of: annotation, in: document)
    }

    // Shims over the shared, cross-platform LinkResolver (existing call
    // sites and tests address these through the view type). See
    // LinkResolution.swift for `currentNavEntry()` / `go(to:in:)` too —
    // they are PDFView extensions now, shared with iOS.

    static func resolveTarget(of annotation: PDFAnnotation, in document: PDFDocument) -> LinkTarget? {
        LinkResolver.target(of: annotation, in: document)
    }

    static func validatedPoint(_ point: CGPoint, on page: PDFPage) -> CGPoint? {
        LinkResolver.validatedPoint(point, on: page)
    }
}
#endif
