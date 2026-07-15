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
    /// Called when the hover peek's Split button is used — opens the target in
    /// a split pane along the given axis.
    var onLinkSplit: ((_ target: LinkTarget, _ axis: SplitAxis) -> Void)?

    /// A "step" back/forward from a bare arrow key. Wired by the Coordinator to
    /// its `goToPreviousPage`/`goToNextPage` so arrow keys take the SAME path as
    /// the status-bar arrows and palette commands — in continuous modes that
    /// lands the target page/row's top at margin M (NAV-1/NAV-2) instead of
    /// PDFKit's own one-inset paging (Fact 4). Nil in previews/tests → fall back
    /// to PDFView's default paging.
    var onStepBackward: (() -> Void)?
    var onStepForward: (() -> Void)?

    /// Left/right arrows page-turn in every display mode. PDFView pages on
    /// arrows in single-page mode but scrolls (or beeps) in the continuous
    /// modes; intercepting here makes the behavior uniform, matching Preview.
    /// Only bare arrows are taken — modified arrows (⇧ selection, ⌘ etc.)
    /// keep PDFView's behavior, and text fields are their own responder so
    /// typing is unaffected. Routed through the Coordinator's step (NAV-1/NAV-2)
    /// when wired; PDFView's own paging is the fallback.
    override func keyDown(with event: NSEvent) {
        cancelLinkHover()
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty,
           let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            switch Int(scalar.value) {
            case NSRightArrowFunctionKey:
                stepForward()
                return  // consume even at the last page (no beep/side-scroll)
            case NSLeftArrowFunctionKey:
                stepBackward()
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

    /// Off = no hover panel, and PDFKit's own "Go to page N" tooltip is left
    /// alone (we stop suppressing it). Pushed from `AppSettings` by
    /// `ActivePDFView.updateNSView`.
    var hoverPreviewEnabled = true {
        didSet {
            guard hoverPreviewEnabled != oldValue else { return }
            if !hoverPreviewEnabled { cancelLinkHover() }
        }
    }

    override func layout() {
        super.layout()
        if hoverPreviewEnabled { suppressToolTips(in: self) }
    }

    /// Kills PDFKit's per-link "Go to page N" tooltip so the peek panel is the
    /// only hover affordance. `removeAllToolTips()` alone doesn't do it —
    /// PDFKit sets the `toolTip` STRING PROPERTY on its inner document view, so
    /// clear that too, across the whole subtree. Re-run after PDFKit re-sets it
    /// (on relayout and in `mouseMoved`).
    private func suppressToolTips(in view: NSView) {
        view.toolTip = nil
        view.removeAllToolTips()
        for subview in view.subviews { suppressToolTips(in: subview) }
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
            // `.activeInActiveApp`, not `.activeInKeyWindow`: while the peek
            // panel is the key window, the reader still needs to see the
            // pointer leave/enter links.
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        linkHoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Preview off: leave PDFKit's tooltip in place, do nothing else.
        guard hoverPreviewEnabled else { return }
        // Clear the tooltip PDFKit just set for the link under the pointer,
        // before the pointer goes still and it would appear.
        suppressToolTips(in: self)

        let viewPoint = convert(event.locationInWindow, from: nil)
        // Preview same-document links only (v1). Remote links still navigate.
        guard let hovered = hoveredLink(atViewPoint: viewPoint),
              hovered.target.remoteFileURL == nil else {
            // Off any link: cancel a pending show. A SHOWN panel dismisses
            // itself geometrically (its safe-region poll), so the pointer can
            // still travel the funnel from the link onto the panel.
            hoverTimer?.invalidate()
            hoverTimer = nil
            hoverTarget = nil
            return
        }
        // Over the link the panel already shows (or one already scheduled):
        // nothing to do — the poll keeps it alive.
        if LinkPreviewPanel.shared.isShowing(target: hovered.target)
            || hovered.target == hoverTarget { return }
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
        // Cancel a pending show; a shown panel's own poll handles dismissal.
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverTarget = nil
    }

    /// True once the current swipe gesture has already turned a page, so one
    /// continuous two-finger swipe advances exactly one page (its momentum tail
    /// and the rest of the gesture are swallowed).
    private var swipeTurnedPage = false

    /// Minimum accumulated swipe delta (points) before a fixed-mode swipe turns
    /// the page — filters out tiny incidental scrolls.
    private static let swipeTurnThreshold: CGFloat = 12

    override func scrollWheel(with event: NSEvent) {
        cancelLinkHover()
        // FIXED modes: the page/spread already fits, so panning it "a little"
        // instead of turning is just noise — lock panning and let a decisive
        // swipe (either axis) turn the page cleanly (#59 bug 7). Continuous
        // modes scroll normally.
        guard
            let mode = ViewMode(displayModeRaw: displayMode.rawValue),
            !mode.isContinuous
        else {
            super.scrollWheel(with: event)
            return
        }
        // A trackpad gesture reports a phase (.began/.changed/.ended) or a
        // momentum phase; a mouse wheel reports neither (discrete events).
        let isGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if event.phase.contains(.began) { swipeTurnedPage = false }
        // Within ONE trackpad gesture, turn a single page and swallow the rest
        // (including the inertial tail). Discrete mouse-wheel notches are
        // independent, so each may turn a page.
        if isGesture {
            guard event.momentumPhase.isEmpty, !swipeTurnedPage else { return }
        }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        // Dominant axis decides; natural-scroll sign: swipe up / left → forward.
        let delta = abs(dx) > abs(dy) ? dx : dy
        guard abs(delta) >= Self.swipeTurnThreshold else { return }
        if isGesture { swipeTurnedPage = true }
        if delta < 0 { stepForward() } else { stepBackward() }
        // Deliberately NOT calling super → the internal scroll view never pans.
    }

    /// One page/spread forward via the Coordinator's step (falls back to
    /// PDFView paging when unwired, e.g. previews/tests).
    private func stepForward() {
        if let onStepForward { onStepForward() }
        else if canGoToNextPage { goToNextPage(nil) }
    }

    private func stepBackward() {
        if let onStepBackward { onStepBackward() }
        else if canGoToPreviousPage { goToPreviousPage(nil) }
    }

    private func showLinkHover() {
        guard let hoverTarget, let hoverViewRect, let document, let window else { return }
        let anchorScreenRect = window.convertToScreen(convert(hoverViewRect, to: nil))
        let current = currentNavEntry()  // position to return to if opened
        LinkPreviewPanel.shared.show(
            document: document,
            target: hoverTarget,
            contentScale: scaleFactor,  // book's on-screen scale → readable at size
            anchorScreenRect: anchorScreenRect,
            parent: window,
            onChoose: { [weak self] action in
                guard let self else { return }
                switch action {
                case .here: self.onLinkActivated?(hoverTarget, current, false)
                case .newTab: self.onLinkActivated?(hoverTarget, current, true)
                case .split(let axis): self.onLinkSplit?(hoverTarget, axis)
                }
            }
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
