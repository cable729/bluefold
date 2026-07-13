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
        cancelLinkHover()
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

    /// Fired on any mouse-down, before link handling — clicking a pane
    /// focuses it (round-14 split semantics).
    var onInteract: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        cancelLinkHover()
        onInteract?()
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let target = linkTarget(atViewPoint: viewPoint), let onLinkActivated {
            let inNewTab = event.modifierFlags.contains(.command)
            onLinkActivated(target, currentNavEntry(), inNewTab)
            return
        }
        super.mouseDown(with: event)
    }

    private func linkTarget(atViewPoint viewPoint: CGPoint) -> LinkTarget? {
        hoveredLink(atViewPoint: viewPoint)?.target
    }

    /// A previewable link under the pointer, with its view-space rect for
    /// anchoring the hover card. Non-previewable results (no annotation,
    /// non-link, or resolves to nil) yield nil.
    private func hoveredLink(atViewPoint viewPoint: CGPoint)
        -> (target: LinkTarget, viewRect: CGRect)? {
        guard
            let page = page(for: viewPoint, nearest: false),
            let annotation = page.annotation(at: convert(viewPoint, to: page)),
            let document,
            let target = Self.resolveTarget(of: annotation, in: document)
        else { return nil }
        return (target, convert(annotation.bounds, from: page))
    }

    // MARK: - Hover preview (Zotero-style link peek)

    /// Settle time before the card appears, long enough not to flicker as the
    /// pointer crosses links while reading.
    private static let hoverDelay: TimeInterval = 0.45

    /// PDFKit tags every internal link with a "Go to page N" help tooltip on
    /// hover; the peek panel replaces it, so swallow the registration.
    override func addToolTip(
        _ rect: NSRect, owner: Any, userData data: UnsafeMutableRawPointer?
    ) -> NSView.ToolTipTag {
        0
    }

    /// Tracking area delivering `mouseMoved` while the pointer is inside.
    private var linkHoverTracking: NSTrackingArea?
    /// The link the pointer currently rests on (scheduled or shown), and its
    /// view-space rect — used to detect leaving and to anchor the card.
    private var hoverTarget: LinkTarget?
    private var hoverViewRect: CGRect?
    private var hoverTimer: Timer?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkHoverTracking { removeTrackingArea(linkHoverTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        linkHoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let viewPoint = convert(event.locationInWindow, from: nil)
        // Preview same-document links only (v1). Remote links still navigate.
        guard let hovered = hoveredLink(atViewPoint: viewPoint),
              hovered.target.remoteFileURL == nil else {
            // Off any link: let the panel dismiss after its grace, so the
            // pointer can still travel from the link onto the panel to scroll.
            hoverTimer?.invalidate()
            hoverTimer = nil
            hoverTarget = nil
            LinkPreviewPanel.shared.scheduleHide()
            return
        }
        // Back over the link the panel already shows: keep it up.
        if LinkPreviewPanel.shared.isShowing(target: hovered.target) {
            LinkPreviewPanel.shared.keepAlive()
            hoverTarget = hovered.target
            return
        }
        if hovered.target == hoverTarget { return }  // already scheduled
        hoverTimer?.invalidate()
        hoverTarget = hovered.target
        hoverViewRect = hovered.viewRect
        hoverTimer = Timer.scheduledTimer(
            withTimeInterval: Self.hoverDelay, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showLinkHover() }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // The pointer may be heading for the panel — dismiss on a grace, which
        // the panel cancels if the pointer arrives inside it.
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverTarget = nil
        LinkPreviewPanel.shared.scheduleHide()
    }

    override func scrollWheel(with event: NSEvent) {
        cancelLinkHover()
        super.scrollWheel(with: event)
    }

    private func showLinkHover() {
        guard let hoverTarget, let hoverViewRect, let document, let window else { return }
        let anchorScreenRect = window.convertToScreen(convert(hoverViewRect, to: nil))
        LinkPreviewPanel.shared.show(
            document: document,
            target: hoverTarget,
            contentScale: scaleFactor,  // book's on-screen scale → readable at size
            anchorScreenRect: anchorScreenRect,
            parent: window
        )
    }

    /// Immediately dismisses a pending or shown hover panel and clears state.
    func cancelLinkHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverTarget = nil
        hoverViewRect = nil
        LinkPreviewPanel.shared.hideNow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelLinkHover() }
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
