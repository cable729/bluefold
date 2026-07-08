#if os(macOS)
import AppKit
import ReaderCore
import SwiftUI

/// A live drag-to-split drop target: dropping a torn-off tab here opens it
/// as `windowID`'s split pane on `side`.
struct SplitDropZone: Equatable {
    let windowID: UUID
    let side: SplitSide
    /// The half of the content area to highlight, in screen coordinates.
    let highlightScreenRect: CGRect
}

/// Screen-level registry of reader windows' PDF content areas, the
/// drag-to-split counterpart of `TabStripRegistry`: a torn-off tab dragged
/// over a window's content area highlights the left or right HALF (whichever
/// holds the pointer); releasing opens the tab as that window's split on
/// that side. The highlight is one shared non-activating panel that ignores
/// mouse events, so it can never steal the drag's tracking.
@MainActor
final class SplitDropZoneRegistry {
    static let shared = SplitDropZoneRegistry()

    private struct Entry {
        weak var view: NSView?
    }

    private var entries: [UUID: Entry] = [:]
    private var overlay: SplitDropOverlayPanel?
    private(set) var currentTarget: SplitDropZone?

    /// Test hook: whether the half-highlight is on screen right now.
    var isHighlightVisible: Bool { overlay?.isVisible == true }

    func register(_ view: NSView, for windowID: UUID) {
        entries[windowID] = Entry(view: view)
    }

    func unregister(windowID: UUID) {
        entries[windowID] = nil
    }

    /// Unregisters only while `view` still owns the entry — a torn-down
    /// accessor must never evict a successor that re-registered the same
    /// window (SwiftUI can rebuild the accessor before releasing the old
    /// one).
    func unregister(windowID: UUID, ifOwnedBy view: NSView) {
        let current = entries[windowID]?.view
        if current == nil || current === view {
            entries[windowID] = nil
        }
    }

    /// The drop zone under a screen point, respecting window z-order: the
    /// FRONTMOST window under the pointer decides. If that window hosts no
    /// registered content area — the library window, or the pointer sits
    /// over a sidebar/strip/status bar — there is no split target; falling
    /// through to a window behind it would highlight something the pointer
    /// visually isn't over. Panels that ignore mouse events (the drag ghost,
    /// this registry's own highlight) never occlude.
    func zone(at screenPoint: CGPoint) -> SplitDropZone? {
        for window in NSApp.orderedWindows {
            guard window.isVisible, !window.ignoresMouseEvents else { continue }
            guard window.frame.contains(screenPoint) else { continue }
            guard let (id, view) = entry(in: window) else { return nil }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            guard rect.contains(screenPoint) else { return nil }
            let side = Self.side(for: screenPoint, in: rect)
            return SplitDropZone(
                windowID: id,
                side: side,
                highlightScreenRect: Self.halfRect(of: rect, side: side)
            )
        }
        return nil
    }

    private func entry(in window: NSWindow) -> (UUID, NSView)? {
        for (id, entry) in entries {
            if let view = entry.view, view.window === window {
                return (id, view)
            }
        }
        return nil
    }

    /// Which half of `rect` the point is in — pure geometry, unit-testable.
    static func side(for point: CGPoint, in rect: CGRect) -> SplitSide {
        point.x < rect.midX ? .leading : .trailing
    }

    static func halfRect(of rect: CGRect, side: SplitSide) -> CGRect {
        switch side {
        case .leading:
            CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .trailing:
            CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        }
    }

    /// Shows the half-highlight over `zone`, or hides it for nil. Idempotent;
    /// every drag-termination path (drop, cancel, failsafe monitors) must
    /// funnel a nil through here so the overlay can never outlive its drag.
    func setTarget(_ zone: SplitDropZone?) {
        guard zone != currentTarget else { return }
        currentTarget = zone
        guard let zone else {
            overlay?.orderOut(nil)
            return
        }
        let panel = overlay ?? SplitDropOverlayPanel()
        overlay = panel
        panel.setFrame(zone.highlightScreenRect.insetBy(dx: 5, dy: 5), display: true)
        panel.orderFrontRegardless()
    }
}

/// Translucent accent highlight over one half of a window's content area.
/// Non-activating and mouse-transparent: it exists purely to be seen and can
/// never steal events from the drag that summoned it.
@MainActor
private final class SplitDropOverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        // One notch below .floating so the drag's ghost panel (at .floating)
        // always renders above the highlight.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.18).cgColor
        box.layer?.borderColor = NSColor.controlAccentColor
            .withAlphaComponent(0.6).cgColor
        box.layer?.borderWidth = 2
        box.layer?.cornerRadius = 8
        contentView = box
    }
}

/// Invisible background view registering the reader window's PDF content
/// area with `SplitDropZoneRegistry`. Never participates in hit-testing.
struct SplitDropZoneAccessor: NSViewRepresentable {
    let windowID: UUID
    let isEnabled: Bool

    func makeNSView(context: Context) -> ZoneView {
        let view = ZoneView()
        view.windowID = windowID
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: ZoneView, context: Context) {
        view.windowID = windowID
        view.isEnabled = isEnabled
        view.refreshRegistration()
    }

    @MainActor
    final class ZoneView: NSView {
        var windowID: UUID?
        var isEnabled = false

        /// Purely a geometry marker; clicks must reach the PDF beneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshRegistration()
        }

        func refreshRegistration() {
            guard let windowID else { return }
            if isEnabled, window != nil {
                SplitDropZoneRegistry.shared.register(self, for: windowID)
            } else {
                SplitDropZoneRegistry.shared.unregister(windowID: windowID, ifOwnedBy: self)
            }
        }
    }
}
#endif
