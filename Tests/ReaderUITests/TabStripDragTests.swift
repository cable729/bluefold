#if os(macOS)
import AppKit
import ReaderCore
import Testing

@testable import ReaderUI

/// Drives the tab strip's mouse state machine with crafted NSEvents in real
/// NSWindows — covering the tear-off / cross-window drop decisions that
/// synthesized XCUITest drags cannot exercise reliably on every machine.
/// (The reorder path is additionally covered end-to-end by the XCUITest
/// smoke suite; SmokeUITests.testDragReordersTabsWithinWindow.)
@Suite("Tab strip drag state machine", .serialized)
@MainActor
struct TabStripDragTests {

    /// One strip hosted in a real (ordered-out) window, plus recorded actions.
    @MainActor
    final class Harness {
        let window: NSWindow
        let strip: TabStripNSView
        let windowID = UUID()

        var reorders: [(UUID, Int)] = []
        var moves: [(UUID, TabStripID, Int)] = []
        var detaches: [(UUID, CGPoint)] = []

        static func item(title: String, breadcrumb: String = "p.1", isActive: Bool = false, groupKey: String? = nil) -> TabDisplayItem {
            TabDisplayItem(
                id: UUID(), title: title, breadcrumb: breadcrumb,
                isActive: isActive, groupKey: groupKey ?? "/tmp/\(title).pdf",
                tint: BookTint.color(forPath: groupKey ?? "/tmp/\(title).pdf")
            )
        }

        init(frame: NSRect, tabs: [String]) {
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
            actions.reorder = { [self] in reorders.append(($0, $1)) }
            actions.moveToStrip = { [self] in moves.append(($0, $1, $2)) }
            actions.detachToNewWindow = { [self] in detaches.append(($0, $1)) }
            strip.actions = actions

            strip.frame = NSRect(x: 0, y: frame.height - 60, width: frame.width, height: TabStripNSView.stripHeight)
            window.contentView?.addSubview(strip)
            strip.apply(
                items: tabs.map { Self.item(title: $0) },
                palette: .light, isWindowSplit: false
            )
            strip.layoutSubtreeIfNeeded()
            // Force layout so item frames are real.
            strip.layout()
            // Show the window offscreen-ish so screen conversions work.
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

        /// Simulates press at an item, a series of window-space drag points,
        /// and release at the last point.
        func drag(item index: Int, through points: [CGPoint]) {
            let item = itemView(at: index)
            let start = CGPoint(x: item.frame.midX, y: strip.frame.minY + 16)
            strip.beginPress(on: item, with: event(.leftMouseDown, windowPoint: start))
            for p in points {
                strip.continuePress(with: event(.leftMouseDragged, windowPoint: p))
            }
            strip.endPress(with: event(.leftMouseUp, windowPoint: points.last ?? start))
        }

        func cleanUp() {
            window.close()
        }
    }

    @Test func horizontalDragCommitsReorder() {
        let h = Harness(
            frame: NSRect(x: 100, y: 300, width: 700, height: 400),
            tabs: ["Alpha", "Beta", "Gamma"]
        )
        defer { h.cleanUp() }
        let gammaID = h.strip.items[2].id

        // Drag Gamma leftward to Alpha's slot, staying inside the strip band.
        let y = h.strip.frame.minY + 16
        h.drag(item: 2, through: [
            CGPoint(x: 400, y: y), CGPoint(x: 220, y: y), CGPoint(x: 120, y: y),
        ])

        #expect(h.reorders.count == 1)
        #expect(h.reorders.first?.0 == gammaID)
        #expect(h.reorders.first?.1 == 0)
        #expect(h.moves.isEmpty && h.detaches.isEmpty)
    }

    @Test func dragBelowBandDetachesToNewWindow() {
        let h = Harness(
            frame: NSRect(x: 100, y: 300, width: 700, height: 400),
            tabs: ["Alpha", "Beta"]
        )
        defer { h.cleanUp() }
        let betaID = h.strip.items[1].id

        // Straight down, far past the tear-off threshold, nowhere near
        // another strip.
        let startY = h.strip.frame.minY + 16
        h.drag(item: 1, through: [
            CGPoint(x: 400, y: startY - 60),
            CGPoint(x: 420, y: startY - 200),
        ])

        #expect(h.detaches.count == 1)
        #expect(h.detaches.first?.0 == betaID)
        #expect(h.reorders.isEmpty && h.moves.isEmpty)
    }

    @Test func dropOnAnotherStripMovesTab() {
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

        // Screen point over the middle of the target strip, converted into
        // the SOURCE window's coordinates (events belong to the mouse-down
        // window during a drag).
        let targetStripScreen = target.window.convertToScreen(
            target.strip.convert(target.strip.bounds, to: nil)
        )
        let dropScreen = CGPoint(x: targetStripScreen.midX, y: targetStripScreen.midY)
        let dropInSource = source.window.convertPoint(fromScreen: dropScreen)

        source.drag(item: 1, through: [
            CGPoint(x: 500, y: source.strip.frame.minY - 100), // tear off first
            dropInSource,
        ])

        #expect(source.moves.count == 1)
        #expect(source.moves.first?.0 == betaID)
        #expect(source.moves.first?.1 == TabStripID(windowID: target.windowID, pane: .primary))
        #expect(source.detaches.isEmpty && source.reorders.isEmpty)
    }

    @Test func adjacentSameBookTabsShareOneLozenge() {
        let h = Harness(
            frame: NSRect(x: 100, y: 300, width: 800, height: 400),
            tabs: ["Alpha", "Axler", "Axler2", "Beta"]
        )
        defer { h.cleanUp() }
        // Rebuild items so the two middle tabs share a book (same groupKey).
        h.strip.apply(items: [
            Harness.item(title: "Alpha"),
            Harness.item(title: "Axler", breadcrumb: "Ch 1 › 1A", isActive: true, groupKey: "/tmp/axler.pdf"),
            Harness.item(title: "Axler", breadcrumb: "Ch 5 › 5B", groupKey: "/tmp/axler.pdf"),
            Harness.item(title: "Beta", breadcrumb: "p.9"),
        ], palette: .light, isWindowSplit: false)
        h.strip.layout()

        // Three books → three lozenges; the Axler one spans BOTH its cells.
        let lozenges = h.strip.subviews.compactMap { $0 as? TabLozengeView }
            .sorted { $0.frame.minX < $1.frame.minX }
        #expect(lozenges.count == 3)

        let cells = h.strip.subviews.compactMap { $0 as? TabItemNSView }
            .sorted { $0.frame.minX < $1.frame.minX }
        let axlerCells = cells[1...2]
        let axlerLozenge = lozenges[1]
        #expect(axlerLozenge.frame.minX < axlerCells.first!.frame.minX,
                "the lozenge leads with the book label, before the first cell")
        #expect(abs(axlerLozenge.frame.maxX - axlerCells.last!.frame.maxX) < 0.5)

        // Every cell sits inside its lozenge band (no spanning header row).
        #expect(cells.allSatisfy { $0.frame.height == axlerLozenge.frame.height })
    }

    @Test func overflowGrowsContentWidthForScrolling() {
        // Firefox/Chrome behavior: past the shrink floor the strip's content
        // outgrows the viewport (the scroll view shows the rest) instead of
        // squeezing tabs to nothing.
        let h = Harness(
            frame: NSRect(x: 100, y: 300, width: 500, height: 400),
            tabs: (1...24).map { "Book \($0)" }
        )
        defer { h.cleanUp() }
        #expect(h.strip.frame.width > 500)
        let cells = h.strip.subviews.compactMap { $0 as? TabItemNSView }
        #expect(cells.allSatisfy { $0.frame.width >= TabStripNSView.minCellWidth - 0.5 })
    }

    @Test func tinyDragIsAClickNotAReorder() {
        let h = Harness(
            frame: NSRect(x: 100, y: 300, width: 700, height: 400),
            tabs: ["Alpha", "Beta"]
        )
        defer { h.cleanUp() }

        let item = h.itemView(at: 0)
        let start = CGPoint(x: item.frame.midX, y: h.strip.frame.minY + 16)
        h.strip.beginPress(on: item, with: h.event(.leftMouseDown, windowPoint: start))
        h.strip.continuePress(with: h.event(
            .leftMouseDragged,
            windowPoint: CGPoint(x: start.x + 2, y: start.y + 1)
        ))
        h.strip.endPress(with: h.event(
            .leftMouseUp,
            windowPoint: CGPoint(x: start.x + 2, y: start.y + 1)
        ))

        #expect(h.reorders.isEmpty && h.moves.isEmpty && h.detaches.isEmpty)
    }
}
#endif
