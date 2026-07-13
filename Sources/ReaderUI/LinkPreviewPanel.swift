#if os(macOS)
import AppKit
import PDFKit
import ReaderCore
import SwiftUI

/// What the macOS peek's buttons request — mirrors the iOS `LinkOpenMode`.
enum LinkPeekAction {
    case here
    case newTab
    case split(SplitAxis)
}

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
    /// SwiftUI-hosted button row (identical design to iOS; themed via
    /// `DesignPalette.current`, which SwiftUI re-reads on theme change).
    private lazy var buttonHost = NSHostingView(
        rootView: LinkPeekButtonRow { [weak self] action in self?.choose(action) })

    /// The peek becomes key so the pointing-hand cursor works over its buttons
    /// (cursor rects only take effect in the KEY window). It's a CHILD of the
    /// reader, so the reader stays drawn as the active/main window; key returns
    /// to it automatically when the peek orders out.
    override var canBecomeKey: Bool { true }
    /// Fired when the user picks an action from the peek's buttons.
    private var onChoose: ((LinkPeekAction) -> Void)?

    /// The peek stays open while the pointer is inside the "safe region" — the
    /// panel (plus minimal padding) UNION a funnel to the originating link (the
    /// convex hull of the two rects). This is the standard hover-menu safe
    /// triangle: you can cut diagonally from the link toward the panel without
    /// it closing, but wandering elsewhere dismisses immediately. A ~40ms poll
    /// of the pointer drives it (mouse-moved events don't reach a non-key
    /// window reliably); geometry, not a time grace.
    private var pollTimer: Timer?
    /// Local monitor that dismisses the peek the moment the user scrolls the
    /// main reader (or anything else in the app). Scrolling INSIDE the preview
    /// keeps it open so the target can be read — a `PDFView` swallows its own
    /// scroll in its inner scroll view, so the reader's `scrollWheel` never sees
    /// it and can't drive this; a monitor catches every scroll app-wide.
    private var scrollMonitor: Any?
    private var linkScreenRect: NSRect = .zero
    private static let safePadding: CGFloat = 4

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
        hasShadow = false  // card carries its own layer shadow; the button area is clear
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .floating

        // The preview card: rounded, bordered, with a drop shadow. The pdfView
        // clips itself to the rounded corners.
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.masksToBounds = false
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.28
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = CGSize(width: 0, height: -5)
        card.translatesAutoresizingMaskIntoConstraints = false

        pdfView.wantsLayer = true
        pdfView.layer?.cornerRadius = 10
        pdfView.layer?.masksToBounds = true
        pdfView.autoScales = false
        pdfView.displaysPageBreaks = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pdfView)

        // Action buttons sit BELOW the preview, floating on the clear panel
        // (no bar behind them), with a gap matching the padding around them.
        buttonHost.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)
        container.addSubview(buttonHost)
        contentView = container

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: container.topAnchor),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: card.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            buttonHost.topAnchor.constraint(equalTo: card.bottomAnchor, constant: buttonGap),
            buttonHost.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            buttonHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Gap between the preview and the floating button row, and the row's
    /// height — reserved below the preview when sizing the panel.
    private let buttonGap: CGFloat = 12
    private let buttonRowHeight: CGFloat = 34

    private func choose(_ action: LinkPeekAction) {
        let handler = onChoose
        hideNow()
        handler?(action)
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
        anchorScreenRect: CGRect, parent: NSWindow,
        onChoose: @escaping (LinkPeekAction) -> Void
    ) {
        self.onChoose = onChoose
        if isShowing(target: target) { return }

        pdfView.backgroundColor = ThemeManager.shared.pdfBackground
        guard let columnWidth = LinkPreview.configure(
            pdfView, document: document, target: target, contentScale: contentScale
        ) else { return }
        shownTarget = target
        shownDocument = document

        // Size and position relative to the WINDOW, not the whole screen —
        // otherwise the panel balloons far larger than the app. Width tracks
        // the text column at book scale (centered, gutters both sides) so every
        // line reads end-to-end; a wider column scrolls horizontally.
        let win = parent.frame
        // Reserve the button row (+ gap) below the preview; the whole panel
        // (preview + buttons) stays within the window.
        let buttonArea = buttonGap + buttonRowHeight
        let preview = LinkPreview.panelSize(
            columnWidth: columnWidth, contentScale: contentScale,
            maxWidth: win.width * 0.92,
            maxHeight: win.height * 0.62 - buttonArea
        )
        let size = CGSize(width: preview.width, height: preview.height + buttonArea)

        let gap: CGFloat = 4
        var origin = CGPoint(
            x: anchorScreenRect.minX,
            y: anchorScreenRect.minY - gap - size.height
        )
        if origin.y < win.minY { origin.y = anchorScreenRect.maxY + gap }
        origin.x = min(max(origin.x, win.minX + 8), win.maxX - size.width - 8)
        origin.y = min(max(origin.y, win.minY + 8), win.maxY - size.height - 8)

        setFrame(CGRect(origin: origin, size: size), display: true)
        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
        linkScreenRect = anchorScreenRect
        installTracking()
        startPoll()
        startScrollDismiss()
        // Scroll to the destination once the view has taken its frame.
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = self.shownDocument, let target = self.shownTarget
            else { return }
            LinkPreview.scroll(self.pdfView, to: target, in: document)
        }
    }

    // MARK: - Hide coordination (safe-region poll)

    private func startPoll() {
        stopPoll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panelShown else { return }
                if !self.inSafeRegion(NSEvent.mouseLocation) { self.hideNow() }
            }
        }
    }

    private func stopPoll() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Dismiss on the first scroll anywhere but inside the preview itself.
    private func startScrollDismiss() {
        stopScrollDismiss()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.panelShown else { return }
                // `event.window` is the panel only when the pointer is over the
                // preview (scrolling to read the target) — keep it open then.
                if event.window !== self { self.hideNow() }
            }
            return event
        }
    }

    private func stopScrollDismiss() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    func hideNow() {
        stopPoll()
        stopScrollDismiss()
        parent?.removeChildWindow(self)
        orderOut(nil)
        shownTarget = nil
        shownDocument = nil
        onChoose = nil
        linkScreenRect = .zero
        pdfView.document = nil
    }

    /// The pointer (screen coords) is inside the panel-plus-funnel safe region:
    /// the convex hull of the padded panel and the originating link.
    private func inSafeRegion(_ point: NSPoint) -> Bool {
        let padded = frame.insetBy(dx: -Self.safePadding, dy: -Self.safePadding)
        let hull = Self.convexHull(Self.corners(of: padded) + Self.corners(of: linkScreenRect))
        return Self.pointInPolygon(point, hull)
    }

    // MARK: - Pointer tracking (key handoff for the cursor)

    private func installTracking() {
        guard let container = contentView else { return }
        for area in container.trackingAreas { container.removeTrackingArea(area) }
        container.addTrackingArea(NSTrackingArea(
            rect: container.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        // Become key only WHILE the pointer is over the panel, so the
        // pointing-hand cursor works over the buttons. Keying on show instead
        // made the reader resign key and dismissed the peek immediately.
        makeKey()
    }

    override func mouseExited(with event: NSEvent) {
        parent?.makeKey()  // hand key back to the reader
    }

    // MARK: - Geometry (convex hull + point-in-polygon)

    private static func corners(of r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY)]
    }

    /// Andrew's monotone-chain convex hull (counter-clockwise).
    private static func convexHull(_ input: [NSPoint]) -> [NSPoint] {
        let points = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard points.count >= 3 else { return points }
        func cross(_ o: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var hull: [NSPoint] = []
        for p in points {  // lower
            while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }
        let lowerCount = hull.count + 1
        for p in points.dropLast().reversed() {  // upper
            while hull.count >= lowerCount, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }
        hull.removeLast()
        return hull
    }

    private static func pointInPolygon(_ p: NSPoint, _ poly: [NSPoint]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

// MARK: - Button row (shared design with the iOS peek)

/// The macOS peek's floating action buttons, styled to match the iOS overlay:
/// accent-filled capsules with white content, tinted by the live theme accent.
private struct LinkPeekButtonRow: View {
    let onAction: (LinkPeekAction) -> Void

    var body: some View {
        let accent = Color(platformColor: DesignPalette.current.accent)
        HStack(spacing: 8) {
            Button { onAction(.here) } label: {
                Label("Open", systemImage: "arrow.right")
            }
            .buttonStyle(PeekButtonStyle(accent: accent, wide: true))

            Button { onAction(.newTab) } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(PeekButtonStyle(accent: accent))

            Button { onAction(.split(.horizontal)) } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(PeekButtonStyle(accent: accent))

            Button { onAction(.split(.vertical)) } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .buttonStyle(PeekButtonStyle(accent: accent))
        }
    }
}

private struct PeekButtonStyle: ButtonStyle {
    let accent: Color
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(height: 34)
            .padding(.horizontal, wide ? 16 : 13)
            .background(Capsule().fill(accent))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .linkPointer()  // pointing-hand cursor (see below)
    }
}

private extension View {
    /// The pointing-hand cursor on hover. Now that the peek is the key window,
    /// the standard cursor APIs work: `.pointerStyle` on macOS 15+, an
    /// `.onHover` push/pop on macOS 14.
    @ViewBuilder func linkPointer() -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(.link)
        } else {
            self.onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
#endif
