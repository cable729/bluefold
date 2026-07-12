#if os(macOS)
import AppKit
import ReaderCore
import Testing

@testable import ReaderUI

/// Drag-to-split drop zones: pure geometry, screen-level hit-testing, and
/// the tab-strip drag state machine's drop outcomes (which half → which
/// side, same-window guards, overlay cleanup). Crafted NSEvents in real
/// windows, same approach as TabStripDragTests — XCUITest drag synthesis
/// does not work on this machine.
@Suite("Split drop zones", .serialized)
@MainActor
struct SplitDropZoneTests {

    // MARK: - Harness

    /// A strip plus a registered content area in one real (ordered-back)
    /// window, with recorded drop actions.
    @MainActor
    final class Harness {
        let window: NSWindow
        let strip: TabStripNSView
        let contentView: NSView
        let windowID = UUID()

        var reorders: [(UUID, Int)] = []
        var moves: [(UUID, UUID, Int)] = []
        var detaches: [(UUID, CGPoint)] = []
        var splitDrops: [(UUID, UUID, SplitSide)] = []

        init(frame: NSRect, tabs: [String], registersContentArea: Bool = true) {
            window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            var actions = TabStripActions(
                select: { _ in }, close: { _ in }, duplicate: { _ in },
                closeOthers: { _ in }, reorder: { _, _ in },
                moveToStrip: { _, _, _ in }, detachToNewWindow: { _, _ in }
            )
            strip = TabStripNSView(
                stripID: TabStripID(windowID: windowID, pane: .primary),
                actions: actions
            )
            // Content area fills the window below the strip.
            contentView = NSView(frame: NSRect(
                x: 0, y: 0, width: frame.width, height: frame.height - 32
            ))
            actions.reorder = { [self] in reorders.append(($0, $1)) }
            actions.moveToStrip = { [self] in moves.append(($0, $1.windowID, $2)) }
            actions.detachToNewWindow = { [self] in detaches.append(($0, $1)) }
            actions.dropIntoSplit = { [self] in splitDrops.append(($0, $1, $2)) }
            strip.actions = actions

            strip.frame = NSRect(x: 0, y: frame.height - 32, width: frame.width, height: 32)
            window.contentView?.addSubview(strip)
            window.contentView?.addSubview(contentView, positioned: .below, relativeTo: strip)
            if registersContentArea {
                SplitDropZoneRegistry.shared.register(contentView, for: windowID)
            }

            strip.apply(items: tabs.map {
                TabDisplayItem(
                    id: UUID(), title: $0, breadcrumb: "p.1",
                    isActive: false, groupKey: "/tmp/\($0).pdf",
                    tint: BookTint.color(forPath: "/tmp/\($0).pdf")
                )
            }, palette: .light, isWindowSplit: false)
            strip.layoutSubtreeIfNeeded()
            strip.layout()
            window.setFrameOrigin(frame.origin)
            window.orderBack(nil)
        }

        func itemView(at index: Int) -> TabItemNSView {
            strip.subviews.compactMap { $0 as? TabItemNSView }
                .sorted { $0.frame.minX < $1.frame.minX }[index]
        }

        func event(_ type: NSEvent.EventType, windowPoint: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }

        func drag(item index: Int, through points: [CGPoint]) {
            let item = itemView(at: index)
            let start = CGPoint(x: item.frame.midX, y: strip.frame.minY + 16)
            strip.beginPress(on: item, with: event(.leftMouseDown, windowPoint: start))
            for p in points {
                strip.continuePress(with: event(.leftMouseDragged, windowPoint: p))
            }
            strip.endPress(with: event(.leftMouseUp, windowPoint: points.last ?? start))
        }

        /// The content view's rect in screen coordinates.
        var contentScreenRect: CGRect {
            window.convertToScreen(contentView.convert(contentView.bounds, to: nil))
        }

        /// A screen point converted into this window's event coordinates.
        func windowPoint(fromScreen point: CGPoint) -> CGPoint {
            window.convertPoint(fromScreen: point)
        }

        func cleanUp() {
            SplitDropZoneRegistry.shared.unregister(windowID: windowID)
            window.close()
        }
    }

    // MARK: - Pure geometry

    @Test func sideIsDecidedByTheHalfHoldingThePointer() {
        let rect = CGRect(x: 100, y: 100, width: 600, height: 400)
        #expect(SplitDropZoneRegistry.side(
            for: CGPoint(x: 101, y: 300), in: rect) == .leading)
        #expect(SplitDropZoneRegistry.side(
            for: CGPoint(x: 399, y: 300), in: rect) == .leading)
        #expect(SplitDropZoneRegistry.side(
            for: CGPoint(x: 400, y: 300), in: rect) == .trailing)
        #expect(SplitDropZoneRegistry.side(
            for: CGPoint(x: 699, y: 300), in: rect) == .trailing)
    }

    @Test func halfRectsCoverTheirHalves() {
        let rect = CGRect(x: 100, y: 100, width: 600, height: 400)
        #expect(SplitDropZoneRegistry.halfRect(of: rect, side: .leading)
            == CGRect(x: 100, y: 100, width: 300, height: 400))
        #expect(SplitDropZoneRegistry.halfRect(of: rect, side: .trailing)
            == CGRect(x: 400, y: 100, width: 300, height: 400))
    }

    // MARK: - Screen-level hit-testing

    @Test func zoneDetectsHalvesAndMissesOutsideTheContentArea() {
        let h = Harness(
            frame: NSRect(x: 100, y: 300, width: 700, height: 400),
            tabs: ["Alpha", "Beta"]
        )
        defer { h.cleanUp() }

        let rect = h.contentScreenRect
        let left = SplitDropZoneRegistry.shared.zone(
            at: CGPoint(x: rect.minX + 10, y: rect.midY))
        #expect(left?.windowID == h.windowID)
        #expect(left?.side == .leading)

        let right = SplitDropZoneRegistry.shared.zone(
            at: CGPoint(x: rect.maxX - 10, y: rect.midY))
        #expect(right?.side == .trailing)
        #expect(right?.highlightScreenRect
            == SplitDropZoneRegistry.halfRect(of: rect, side: .trailing))

        // Far outside every window: no zone.
        #expect(SplitDropZoneRegistry.shared.zone(
            at: CGPoint(x: rect.maxX + 500, y: rect.minY - 500)) == nil)
    }

    @Test func windowsWithoutARegisteredZoneYieldNoTarget() {
        let h = Harness(
            frame: NSRect(x: 100, y: 300, width: 700, height: 400),
            tabs: ["Alpha"],
            registersContentArea: false // e.g. an empty window, or the library
        )
        defer { h.cleanUp() }

        let rect = h.contentScreenRect
        #expect(SplitDropZoneRegistry.shared.zone(
            at: CGPoint(x: rect.midX, y: rect.midY)) == nil)
    }

    // MARK: - Drag outcomes

    @Test func dropOnAnotherWindowsLeftHalfSplitsLeading() {
        let source = Harness(
            frame: NSRect(x: 100, y: 300, width: 600, height: 400),
            tabs: ["Alpha", "Beta"]
        )
        let target = Harness(
            frame: NSRect(x: 800, y: 300, width: 600, height: 400),
            tabs: ["Gamma"]
        )
        defer {
            source.cleanUp()
            target.cleanUp()
        }
        let betaID = source.strip.items[1].id

        let rect = target.contentScreenRect
        let dropScreen = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.midY)

        source.drag(item: 1, through: [
            CGPoint(x: 500, y: source.strip.frame.minY - 100), // tear off
            source.windowPoint(fromScreen: dropScreen),
        ])

        #expect(source.splitDrops.count == 1)
        #expect(source.splitDrops.first?.0 == betaID)
        #expect(source.splitDrops.first?.1 == target.windowID)
        #expect(source.splitDrops.first?.2 == .leading)
        #expect(source.detaches.isEmpty && source.moves.isEmpty && source.reorders.isEmpty)
        #expect(!SplitDropZoneRegistry.shared.isHighlightVisible,
                "the overlay must be cleaned up when the drag ends")
    }

    @Test func dropOnTheRightHalfSplitsTrailingAndHighlightsMidDrag() {
        let source = Harness(
            frame: NSRect(x: 100, y: 300, width: 600, height: 400),
            tabs: ["Alpha", "Beta"]
        )
        let target = Harness(
            frame: NSRect(x: 800, y: 300, width: 600, height: 400),
            tabs: ["Gamma"]
        )
        defer {
            source.cleanUp()
            target.cleanUp()
        }

        let rect = target.contentScreenRect
        let hoverScreen = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.midY)

        // Step the drag by hand so the mid-drag highlight is observable.
        let item = source.itemView(at: 1)
        let start = CGPoint(x: item.frame.midX, y: source.strip.frame.minY + 16)
        source.strip.beginPress(
            on: item, with: source.event(.leftMouseDown, windowPoint: start))
        source.strip.continuePress(with: source.event(
            .leftMouseDragged,
            windowPoint: CGPoint(x: 500, y: source.strip.frame.minY - 100)
        ))
        source.strip.continuePress(with: source.event(
            .leftMouseDragged,
            windowPoint: source.windowPoint(fromScreen: hoverScreen)
        ))
        #expect(SplitDropZoneRegistry.shared.isHighlightVisible)
        #expect(SplitDropZoneRegistry.shared.currentTarget?.side == .trailing)

        source.strip.endPress(with: source.event(
            .leftMouseUp,
            windowPoint: source.windowPoint(fromScreen: hoverScreen)
        ))

        #expect(source.splitDrops.count == 1)
        #expect(source.splitDrops.first?.2 == .trailing)
        #expect(!SplitDropZoneRegistry.shared.isHighlightVisible)
        #expect(SplitDropZoneRegistry.shared.currentTarget == nil)
    }

    @Test func dropOnOwnContentAreaSplitsInPlace() {
        let h = Harness(
            frame: NSRect(x: 100, y: 300, width: 700, height: 400),
            tabs: ["Alpha", "Beta"]
        )
        defer { h.cleanUp() }
        let betaID = h.strip.items[1].id

        let rect = h.contentScreenRect
        let dropScreen = CGPoint(x: rect.maxX - 10, y: rect.midY)
        h.drag(item: 1, through: [
            CGPoint(x: 500, y: h.strip.frame.minY - 100),
            h.windowPoint(fromScreen: dropScreen),
        ])

        #expect(h.splitDrops.count == 1)
        #expect(h.splitDrops.first?.0 == betaID)
        #expect(h.splitDrops.first?.1 == h.windowID)
        #expect(h.splitDrops.first?.2 == .trailing)
        #expect(h.detaches.isEmpty)
    }

    @Test func singleTabWindowCannotSplitAgainstItself() {
        // Dragging the ONLY tab onto the window's own content area: nothing
        // would remain for the primary pane, so it stays a desktop detach.
        let h = Harness(
            frame: NSRect(x: 100, y: 300, width: 700, height: 400),
            tabs: ["Alpha"]
        )
        defer { h.cleanUp() }

        let rect = h.contentScreenRect
        let dropScreen = CGPoint(x: rect.minX + 10, y: rect.midY)
        h.drag(item: 0, through: [
            CGPoint(x: 500, y: h.strip.frame.minY - 100),
            h.windowPoint(fromScreen: dropScreen),
        ])

        #expect(h.splitDrops.isEmpty)
        #expect(h.detaches.count == 1)
        #expect(!SplitDropZoneRegistry.shared.isHighlightVisible)
    }

    @Test func stripDropStillWinsOverTheContentAreaBeneathIt() {
        // The strip's grace band reaches into the content area; a drop there
        // must stay a strip drop (tab move), not become a surprise split.
        let source = Harness(
            frame: NSRect(x: 100, y: 300, width: 600, height: 400),
            tabs: ["Alpha", "Beta"]
        )
        let target = Harness(
            frame: NSRect(x: 800, y: 300, width: 600, height: 400),
            tabs: ["Gamma"]
        )
        defer {
            source.cleanUp()
            target.cleanUp()
        }

        let stripScreen = target.window.convertToScreen(
            target.strip.convert(target.strip.bounds, to: nil))
        let dropScreen = CGPoint(x: stripScreen.midX, y: stripScreen.midY)

        source.drag(item: 1, through: [
            CGPoint(x: 500, y: source.strip.frame.minY - 100),
            source.windowPoint(fromScreen: dropScreen),
        ])

        #expect(source.moves.count == 1)
        #expect(source.splitDrops.isEmpty)
        #expect(!SplitDropZoneRegistry.shared.isHighlightVisible)
    }

    @Test func reEnteringTheStripBandClearsTheHighlight() {
        let h = Harness(
            frame: NSRect(x: 100, y: 300, width: 700, height: 400),
            tabs: ["Alpha", "Beta"]
        )
        defer { h.cleanUp() }

        let rect = h.contentScreenRect
        let hoverScreen = CGPoint(x: rect.minX + 10, y: rect.midY)

        let item = h.itemView(at: 1)
        let start = CGPoint(x: item.frame.midX, y: h.strip.frame.minY + 16)
        h.strip.beginPress(on: item, with: h.event(.leftMouseDown, windowPoint: start))
        h.strip.continuePress(with: h.event(
            .leftMouseDragged, windowPoint: h.windowPoint(fromScreen: hoverScreen)
        ))
        #expect(SplitDropZoneRegistry.shared.isHighlightVisible)

        // Back into the strip band: the ghost dissolves and so must the
        // split highlight.
        h.strip.continuePress(with: h.event(
            .leftMouseDragged, windowPoint: CGPoint(x: start.x + 40, y: start.y)
        ))
        #expect(!SplitDropZoneRegistry.shared.isHighlightVisible)

        h.strip.endPress(with: h.event(
            .leftMouseUp, windowPoint: CGPoint(x: start.x + 40, y: start.y)
        ))
        #expect(h.splitDrops.isEmpty)
    }
}
#endif
