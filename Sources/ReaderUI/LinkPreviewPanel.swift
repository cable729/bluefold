#if os(macOS)
import AppKit
import PDFKit

/// A `PDFView` that swallows PDFKit's per-link "Go to page N" help tags — the
/// preview (and the main reader) shouldn't sprout tooltips on hover.
final class NoToolTipPDFView: PDFView {
    override func addToolTip(
        _ rect: NSRect, owner: Any, userData data: UnsafeMutableRawPointer?
    ) -> NSView.ToolTipTag {
        0  // register nothing
    }
}

/// The floating peek shown while hovering an internal link on macOS: a live,
/// scrollable `PDFView` scrolled to the link's destination at the book's own
/// scale, so it reads at full size and the pointer can move in to scroll it.
///
/// A single shared, borderless, non-activating child panel. Unlike a tooltip it
/// is INTERACTIVE — it owns a tracking area and a short hide grace so moving the
/// pointer off the link and onto the panel keeps it open; leaving the panel (and
/// not returning to the link) dismisses it.
@MainActor
final class LinkPreviewPanel: NSPanel {
    static let shared = LinkPreviewPanel()

    private let card = NSView()
    private let pdfView = NoToolTipPDFView()
    /// Grace before hiding after the pointer leaves the link or the panel —
    /// long enough to cross the small gap between them.
    private let hideGrace: TimeInterval = 0.3
    private var hideTimer: Timer?
    private var pointerInside = false

    /// The link currently previewed; `show` rebuilds only when it changes, so
    /// re-hovering the same link never resets the reader's scroll position.
    private(set) var shownTarget: LinkTarget?
    private weak var shownDocument: PDFDocument?

    /// Presented as a child window (distinct from `NSWindow.isVisible`).
    private var panelShown: Bool { parent != nil }

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .floating

        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        pdfView.autoScales = false
        pdfView.displaysPageBreaks = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pdfView)
        contentView = card

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            card.topAnchor.constraint(equalTo: contentView!.topAnchor),
            card.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: card.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    // MARK: - Show

    /// True if the panel is already presenting `target` (so the caller need only
    /// keep it alive instead of rebuilding).
    func isShowing(target: LinkTarget) -> Bool {
        panelShown && shownTarget == target
    }

    /// Presents (or re-targets) the peek for `target`, anchored near
    /// `anchorScreenRect` (the link's rect in screen coordinates), sized to the
    /// text column at `contentScale`.
    func show(
        document: PDFDocument, target: LinkTarget, contentScale: CGFloat,
        anchorScreenRect: CGRect, parent: NSWindow
    ) {
        cancelHideTimer()
        if isShowing(target: target) { return }

        pdfView.backgroundColor = ThemeManager.shared.pdfBackground
        guard let columnWidth = LinkPreview.configure(
            pdfView, document: document, target: target, contentScale: contentScale
        ) else { return }
        shownTarget = target
        shownDocument = document

        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        // Width tracks the FULL text column at book scale so every line reads
        // end-to-end (the column is auto-cropped on the left; the inset adds a
        // little right breathing room). Only a column wider than most of the
        // screen falls back to horizontal scroll.
        let size = LinkPreview.panelSize(
            columnWidth: columnWidth, contentScale: contentScale,
            maxWidth: visible.width * 0.92,
            maxHeight: min(680, visible.height * 0.8),
            horizontalInset: 10
        )

        let gap: CGFloat = 4
        var origin = CGPoint(
            x: anchorScreenRect.minX,
            y: anchorScreenRect.minY - gap - size.height
        )
        if origin.y < visible.minY { origin.y = anchorScreenRect.maxY + gap }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)

        setFrame(CGRect(origin: origin, size: size), display: true)
        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
        installTracking()
        // Scroll to the destination once the view has taken its frame.
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = self.shownDocument, let target = self.shownTarget
            else { return }
            LinkPreview.scroll(self.pdfView, to: target, in: document)
        }
    }

    // MARK: - Hide coordination

    /// Keeps the panel open (pointer is back over the originating link).
    func keepAlive() { cancelHideTimer() }

    /// Starts the dismiss grace; cancelled if the pointer enters the panel.
    func scheduleHide() {
        guard panelShown, hideTimer == nil else { return }
        hideTimer = Timer.scheduledTimer(
            withTimeInterval: hideGrace, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.pointerInside else { return }
                self.hideNow()
            }
        }
    }

    func hideNow() {
        cancelHideTimer()
        pointerInside = false
        parent?.removeChildWindow(self)
        orderOut(nil)
        shownTarget = nil
        shownDocument = nil
        pdfView.document = nil
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    // MARK: - Pointer tracking (bridge from link → panel)

    private func installTracking() {
        for area in card.trackingAreas { card.removeTrackingArea(area) }
        card.addTrackingArea(NSTrackingArea(
            rect: card.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        cancelHideTimer()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        scheduleHide()
    }
}
#endif
