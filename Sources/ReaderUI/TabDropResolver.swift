#if os(macOS)
import CoreGraphics
import Foundation
import ReaderCore

/// One tab strip resolved into screen geometry for a drop decision.
struct DropStrip: Equatable {
    let id: TabStripID
    /// The strip's hit rect in screen space, including the vertical grace band
    /// that lets a drop just below the bar still count as a strip drop.
    let graceRect: CGRect
    /// Each tab cell's mid-X in screen space, left to right — the insertion
    /// slot for a foreign tab is the first cell whose mid-X the pointer is
    /// left of.
    let itemMidXs: [CGFloat]
}

/// One reader window resolved for a drag-to-split decision. `contentRect` is
/// nil when the window hosts no split target (the library window, an empty
/// window); such a window still OCCLUDES windows behind it.
struct DropWindow: Equatable {
    let id: UUID
    let frame: CGRect
    let contentRect: CGRect?
}

/// What a committed tab drag resolves to. The window-dependent step is only
/// resolving `DropStrip`/`DropWindow` rects (done by the registries from live
/// views); this decision over them is pure, so it is unit-testable headlessly
/// and identical on the CI runner where real cross-window geometry misbehaves
/// (#25/#49).
enum TabDropOutcome: Equatable {
    /// In-band drag: reorder within the source strip to the live preview slot.
    case reorder(index: Int)
    /// Torn off onto another strip (another window or this window's other pane).
    case moveToStrip(TabStripID, index: Int)
    /// Torn off onto a reader window's content-area half.
    case dropIntoSplit(windowID: UUID, side: SplitSide)
    /// Torn off onto empty desktop.
    case detach
    /// Dropped back on the source strip: nothing to do.
    case ownStrip
}

enum TabDropResolver {
    /// Resolves a committed drag. Mirrors `TabStripNSView.finishDrag`:
    /// strips win over content (their grace band overlaps the content top and
    /// a strip drop is the more deliberate gesture there); a same-window split
    /// needs another tab left for the primary pane; the frontmost window under
    /// the pointer decides split targeting, so a zone-less window in front
    /// blocks one behind it.
    static func outcome(
        tornOff: Bool,
        previewIndex: Int,
        at point: CGPoint,
        sourceStripID: TabStripID,
        sourceWindowID: UUID,
        sourceItemCount: Int,
        strips: [DropStrip],
        windows: [DropWindow]
    ) -> TabDropOutcome {
        guard tornOff else { return .reorder(index: previewIndex) }

        // Strips win, frontmost first.
        if let strip = strips.first(where: { $0.graceRect.contains(point) }) {
            return strip.id == sourceStripID
                ? .ownStrip
                : .moveToStrip(strip.id, index: insertionIndex(forX: point.x, midXs: strip.itemMidXs))
        }

        // Split zone: only the FRONTMOST window under the pointer is a
        // candidate — a window in front with no zone blocks one behind.
        if let window = windows.first(where: { $0.frame.contains(point) }),
           let content = window.contentRect, content.contains(point),
           !(window.id == sourceWindowID && sourceItemCount < 2) {
            let side: SplitSide = point.x < content.midX ? .leading : .trailing
            return .dropIntoSplit(windowID: window.id, side: side)
        }

        return .detach
    }

    /// The slot a foreign tab dropped at `x` (screen space) takes: the first
    /// cell whose mid-X the pointer is left of, else the end.
    static func insertionIndex(forX x: CGFloat, midXs: [CGFloat]) -> Int {
        for (index, midX) in midXs.enumerated() where x < midX { return index }
        return midXs.count
    }
}
#endif
