#if os(macOS)
import CoreGraphics
import Foundation
import ReaderCore
import Testing

@testable import ReaderUI

/// Headless coverage of the tab drop DECISION — the same reorder / move /
/// split / detach outcomes that `TabStripDragTests` and `SplitDropZoneTests`
/// exercise by driving real NSWindows, but expressed as pure geometry over
/// screen rects. This is what lets the three CROSS-window scenarios (which the
/// CI runner can't reproduce with real windows, see #25/#49) run in CI: the
/// window-dependent step is only resolving the rects; the decision over them
/// is `TabDropResolver.outcome`, and `finishDrag` routes through it so the
/// instrumented tests exercise the very same function.
@Suite("Tab drop resolver")
struct TabDropResolverTests {

    // Two side-by-side "windows": source W1 at x∈[0,600], target W2 at
    // x∈[800,1400]. Strips sit across the top band (y∈[360,404]); content
    // fills below (y∈[0,360]).
    let w1 = UUID()
    let w2 = UUID()
    var sourceStrip: TabStripID { TabStripID(windowID: w1, pane: .primary) }
    var targetStrip: TabStripID { TabStripID(windowID: w2, pane: .primary) }

    func stripsSourceAndTarget() -> [DropStrip] {
        [
            // front-to-back; only containment matters here
            DropStrip(id: targetStrip,
                      graceRect: CGRect(x: 800, y: 360, width: 600, height: 44),
                      itemMidXs: [900, 1300]),
            DropStrip(id: sourceStrip,
                      graceRect: CGRect(x: 0, y: 360, width: 600, height: 44),
                      itemMidXs: [100, 300]),
        ]
    }

    func windowsSourceAndTarget() -> [DropWindow] {
        [
            DropWindow(id: w2, frame: CGRect(x: 800, y: 0, width: 600, height: 404),
                       contentRect: CGRect(x: 800, y: 0, width: 600, height: 360)),
            DropWindow(id: w1, frame: CGRect(x: 0, y: 0, width: 600, height: 404),
                       contentRect: CGRect(x: 0, y: 0, width: 600, height: 360)),
        ]
    }

    func resolve(tornOff: Bool = true, previewIndex: Int = 0,
                 at point: CGPoint, sourceItemCount: Int = 2) -> TabDropOutcome {
        TabDropResolver.outcome(
            tornOff: tornOff, previewIndex: previewIndex, at: point,
            sourceStripID: sourceStrip, sourceWindowID: w1,
            sourceItemCount: sourceItemCount,
            strips: stripsSourceAndTarget(), windows: windowsSourceAndTarget()
        )
    }

    // MARK: - The three cross-window scenarios (mirror the instrumented tests)

    /// dropOnAnotherStripMovesTab
    @Test func dropOverAnotherStripMovesToThatStrip() {
        // x=1100 → past midX 900, before 1300 → insertion index 1.
        #expect(resolve(at: CGPoint(x: 1100, y: 380))
            == .moveToStrip(targetStrip, index: 1))
    }

    /// dropOnAnotherWindowsLeftHalfSplitsLeading
    @Test func dropOnAnotherWindowsLeftHalfSplitsLeading() {
        #expect(resolve(at: CGPoint(x: 900, y: 180))
            == .dropIntoSplit(windowID: w2, side: .leading))
    }

    /// stripDropStillWinsOverTheContentAreaBeneathIt — the strip's grace band
    /// overlaps the top of the content; a drop in the overlap stays a strip
    /// move, never a surprise split.
    @Test func stripGraceBandBeatsTheContentBeneathIt() {
        // y=362 is inside BOTH the target strip's grace band (360…404) and its
        // content rect (0…360 → just below); strips are checked first.
        let overlap = CGPoint(x: 1100, y: 362)
        #expect(windowsSourceAndTarget()[0].contentRect!.maxY <= 360)
        // Put the point where grace (360+) and a taller content would overlap:
        let tallContent = [
            DropWindow(id: w2, frame: CGRect(x: 800, y: 0, width: 600, height: 404),
                       contentRect: CGRect(x: 800, y: 0, width: 600, height: 380)),
        ]
        let outcome = TabDropResolver.outcome(
            tornOff: true, previewIndex: 0, at: overlap,
            sourceStripID: sourceStrip, sourceWindowID: w1, sourceItemCount: 2,
            strips: stripsSourceAndTarget(), windows: tallContent)
        #expect(outcome == .moveToStrip(targetStrip, index: 1))
    }

    // MARK: - Split side & guards

    @Test func rightHalfSplitsTrailing() {
        #expect(resolve(at: CGPoint(x: 1300, y: 180))
            == .dropIntoSplit(windowID: w2, side: .trailing))
    }

    @Test func sameWindowSingleTabCannotSplitAgainstItself() {
        // Drop over the SOURCE window's own content with only one tab: nothing
        // would remain for the primary pane → detach, not split.
        #expect(resolve(at: CGPoint(x: 300, y: 180), sourceItemCount: 1) == .detach)
    }

    @Test func sameWindowSplitsInPlaceWithTabToSpare() {
        // x=200 is left of W1's content mid-X (300) → leading.
        #expect(resolve(at: CGPoint(x: 200, y: 180), sourceItemCount: 2)
            == .dropIntoSplit(windowID: w1, side: .leading))
    }

    // MARK: - Own strip, detach, reorder

    @Test func dropBackOnOwnStripIsANoOp() {
        #expect(resolve(at: CGPoint(x: 300, y: 380)) == .ownStrip)
    }

    @Test func dropOnEmptyDesktopDetaches() {
        // Far from every window and strip.
        #expect(resolve(at: CGPoint(x: 5000, y: 5000)) == .detach)
    }

    @Test func inBandDragReorders() {
        // Not torn off: the outcome is a reorder to the live preview slot,
        // regardless of pointer position.
        #expect(resolve(tornOff: false, previewIndex: 2, at: CGPoint(x: 1100, y: 380))
            == .reorder(index: 2))
    }

    // MARK: - Occlusion

    @Test func aFrontWindowWithoutASplitZoneBlocksTheOneBehind() {
        // A frontmost window with no content zone (e.g. the library) over the
        // point yields no split target, even if a zone window sits behind it.
        let blocker = DropWindow(id: UUID(),
                                 frame: CGRect(x: 850, y: 0, width: 200, height: 360),
                                 contentRect: nil)
        let zoneBehind = DropWindow(id: w2,
                                    frame: CGRect(x: 800, y: 0, width: 600, height: 360),
                                    contentRect: CGRect(x: 800, y: 0, width: 600, height: 360))
        let outcome = TabDropResolver.outcome(
            tornOff: true, previewIndex: 0, at: CGPoint(x: 900, y: 180),
            sourceStripID: sourceStrip, sourceWindowID: w1, sourceItemCount: 2,
            strips: [], windows: [blocker, zoneBehind])
        #expect(outcome == .detach)
    }
}
#endif
