#if os(macOS)
import CoreGraphics
import PDFKit
import Testing

@testable import ReaderUI

/// #59 bug 3 — two-up + trim cropped to the WRONG (mode-inconsistent) extent.
/// Root cause found on a real 593-page book: the two-up uniform cell was the
/// document-wide MAX over EVERY page, and pages the detector leaves as-is
/// (front matter, figures, covers) fall back to their FULL box — so a few
/// untrimmed pages balloon the cell to full-page size and two-up+trim shows the
/// whole book essentially uncropped, while single+trim crops each page tightly.
///
/// Fix: the two-up trim cell is the max over the DETECTED (trimmed) content
/// boxes only; untrimmed pages keep their own box (no override) instead of
/// inflating everyone else's cell.
@Suite("Bug 3 — two-up trim cell")
struct Bug3CropConsistencyTests {

    /// GIVEN 3 trimmed pages (~300 wide) and 1 untrimmed page (absent from the
    /// detected map). THEN the uniform cell is the max over the TRIMMED pages
    /// (310×500), the untrimmed page gets NO override, and each trimmed page's
    /// box is the tight cell — NOT ballooned by the untrimmed full page.
    @Test func cellFromDetectedOnly_untrimmedPageDoesNotInflate() {
        let detected: [Int: CGRect] = [
            0: CGRect(x: 40, y: 30, width: 300, height: 480),
            1: CGRect(x: 50, y: 20, width: 290, height: 500),
            3: CGRect(x: 45, y: 25, width: 310, height: 470),
            // page 2 is untrimmed (detector returned nil) → not in the map.
        ]
        let overrides = ViewModePlanner.twoUpTrimOverrides(
            detected: detected, layout: .default, vAlign: .center)

        // Untrimmed page keeps its own box (no override).
        #expect(overrides[2] == nil)
        // Cell = max over trimmed pages only.
        let cell = CGSize(width: 310, height: 500)
        #expect(overrides[0]?.size == cell)
        #expect(overrides[1]?.size == cell)
        #expect(overrides[3]?.size == cell)
        // Content still placed spine-ward: page 0 is the left slot → flush right.
        #expect(abs((overrides[0]!.maxX) - detected[0]!.maxX) <= 1e-9)
        // Page 1 is the right slot → flush left.
        #expect(abs((overrides[1]!.minX) - detected[1]!.minX) <= 1e-9)
    }

    /// The WIDEST trimmed page is cropped to the SAME width in two-up as in
    /// single (its own content box), because the cell width equals the max
    /// trimmed width — trim is mode-consistent for the binding page (#59 bug 3).
    @Test func widestTrimmedPageMatchesSingleWidth() {
        let detected: [Int: CGRect] = [
            0: CGRect(x: 40, y: 30, width: 300, height: 480),
            1: CGRect(x: 50, y: 20, width: 340, height: 500),  // widest
        ]
        let overrides = ViewModePlanner.twoUpTrimOverrides(
            detected: detected, layout: .default, vAlign: .center)
        // Single+trim width for page 1 == its content width (340).
        // Two-up+trim width for page 1 == cell width == max trimmed width (340).
        #expect(overrides[1]?.width == detected[1]!.width)
    }

    /// Empty input (nothing detected) yields no overrides — two-up falls back to
    /// the normal enlarge path, not a crash.
    @Test func emptyDetectedYieldsNoOverrides() {
        #expect(ViewModePlanner.twoUpTrimOverrides(
            detected: [:], layout: .default, vAlign: .center).isEmpty)
    }
}
#endif
