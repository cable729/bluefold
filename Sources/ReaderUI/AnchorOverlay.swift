#if os(macOS)
import AppKit
import PDFKit

/// Margin anchor glyphs, rendered through PDFKit's per-page overlay views.
///
/// Probed 2026-07-08 (macOS 26): PDFPageOverlayViewProvider works — overlay
/// views install/remove lazily per visible page and keep PAGE-POINT
/// coordinates at every zoom (PDFKit scales them by transform), unflipped
/// (y-up, matching page space). Overlay origin corresponds to the page's
/// CROP BOX origin, so page-space geometry is shifted by -crop.origin.
@MainActor
final class AnchorOverlayProvider: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    var index: AnchorIndex?
    var onAnchorClicked: ((Anchor, NSEvent.ModifierFlags) -> Void)?

    /// Weak page keys: pages belong to the document; the provider must not
    /// keep them (or their overlay views) alive past display.
    private let overlays = NSMapTable<PDFPage, AnchorPageOverlayView>(
        keyOptions: .weakMemory, valueOptions: .strongMemory
    )

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        guard let index, let document = view.document else { return nil }
        if let existing = overlays.object(forKey: page) { return existing }
        let anchors = index.anchors(forPage: document.index(for: page))
        guard !anchors.isEmpty else { return nil }
        let overlay = AnchorPageOverlayView(
            anchors: anchors, crop: page.bounds(for: .cropBox)
        )
        overlay.onClicked = { [weak self] anchor, modifiers in
            self?.onAnchorClicked?(anchor, modifiers)
        }
        overlays.setObject(overlay, forKey: page)
        return overlay
    }
}

/// One page's overlay: transparent, hit-testable ONLY on the glyphs so page
/// clicks, text selection, and link taps pass through untouched. Draws the
/// hover extent outline (the dashed box showing what a link targets).
@MainActor
final class AnchorPageOverlayView: NSView {
    var onClicked: ((Anchor, NSEvent.ModifierFlags) -> Void)?

    private let crop: CGRect
    private var hoveredLineBounds: CGRect?

    /// Glyph square, in page points (scales with zoom like page content).
    private static let glyphSize: CGFloat = 15
    /// Distance from the crop's left edge to the glyph's leading edge.
    private static let leftInset: CGFloat = 5
    /// Consecutive glyphs closer than this (page points) are nudged apart.
    private static let minGap: CGFloat = 17

    init(anchors: [Anchor], crop: CGRect) {
        self.crop = crop
        super.init(frame: CGRect(origin: .zero, size: crop.size))

        // anchors arrive top-first (descending y); nudge stacked glyphs
        // apart so same-spot-adjacent anchors stay individually clickable.
        var lastTop = CGFloat.greatestFiniteMagnitude
        for anchor in anchors {
            // Center on the heading line when the text tier measured one.
            let centerY = anchor.lineBounds?.midY ?? (anchor.point.y - Self.glyphSize / 2)
            var top = min(centerY + Self.glyphSize / 2, crop.maxY - 2)
            if lastTop - top < Self.minGap {
                top = lastTop - Self.minGap
            }
            lastTop = top
            let glyph = AnchorGlyphView(anchor: anchor)
            glyph.frame = CGRect(
                x: Self.leftInset,
                y: (top - Self.glyphSize) - crop.minY,  // page → overlay space
                width: Self.glyphSize,
                height: Self.glyphSize
            )
            glyph.onClicked = { [weak self] anchor, modifiers in
                self?.onClicked?(anchor, modifiers)
            }
            glyph.onHoverChanged = { [weak self] hovering in
                self?.setHoverExtent(hovering ? anchor.lineBounds : nil)
            }
            addSubview(glyph)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Only glyphs are interactive; the rest of the overlay is air.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is AnchorGlyphView ? hit : nil
    }

    private func setHoverExtent(_ lineBounds: CGRect?) {
        hoveredLineBounds = lineBounds
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let lineBounds = hoveredLineBounds else { return }
        let box = lineBounds
            .offsetBy(dx: -crop.minX, dy: -crop.minY)
            .insetBy(dx: -4, dy: -3)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        path.setLineDash([3, 2.5], count: 2, phase: 0)
        path.lineWidth = 1
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        path.stroke()
    }
}

/// A single clickable margin glyph.
@MainActor
final class AnchorGlyphView: NSView {
    let anchor: Anchor
    var onClicked: ((Anchor, NSEvent.ModifierFlags) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var isHovered = false

    init(anchor: Anchor) {
        self.anchor = anchor
        super.init(frame: .zero)
        toolTip = "Copy link — \(anchor.label)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        onHoverChanged?(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow; acting on mouse-up matches buttons.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -2, dy: -2).contains(point) else { return }
        onClicked?(anchor, event.modifierFlags)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbol = NSImage(
            systemSymbolName: "link", accessibilityDescription: "Copy link"
        ) else { return }
        let tint: NSColor = isHovered
            ? .controlAccentColor
            : .secondaryLabelColor.withAlphaComponent(0.55)
        let config = NSImage.SymbolConfiguration(
            pointSize: bounds.width - 3, weight: isHovered ? .semibold : .regular
        )
        let image = symbol.withSymbolConfiguration(config) ?? symbol
        let tinted = image.tinted(with: tint)
        tinted.draw(
            in: bounds.insetBy(dx: 1, dy: 1),
            from: .zero, operation: .sourceOver, fraction: 1
        )
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        return image
    }
}
#endif
