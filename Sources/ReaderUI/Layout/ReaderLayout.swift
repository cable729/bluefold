import CoreGraphics

/// The reader's four view modes. Raw values are chosen to match
/// `PDFDisplayMode` (singlePage=0, singlePageContinuous=1, twoUp=2,
/// twoUpContinuous=3) so a `ViewMode` round-trips through PDFKit as its raw
/// `Int` without a lookup table (see `displayModeRaw` / `init(displayModeRaw:)`).
public enum ViewMode: Int, Sendable, CaseIterable {
    case singleFixed = 0
    case singleContinuous = 1
    case doubleFixed = 2
    case doubleContinuous = 3

    /// Continuous modes scroll through the whole document; fixed modes show one
    /// page (or one spread) at a time.
    public var isContinuous: Bool {
        self == .singleContinuous || self == .doubleContinuous
    }

    /// Two-up modes lay pages out as side-by-side spreads.
    public var isTwoUp: Bool {
        self == .doubleFixed || self == .doubleContinuous
    }

    /// The `PDFDisplayMode` raw value this mode maps to (== `rawValue`).
    public var displayModeRaw: Int { rawValue }

    /// Rebuilds a `ViewMode` from a `PDFDisplayMode` raw value; `nil` for any
    /// value outside 0...3.
    public init?(displayModeRaw: Int) {
        self.init(rawValue: displayModeRaw)
    }
}

/// How a two-up mode pairs pages into spreads. `displaysAsBook` ON makes page
/// index 0 sit ALONE (a book's odd-numbered first recto), so pairs become
/// (1,2),(3,4)…; OFF pairs (0,1),(2,3)…. `rtl` swaps which page of a pair is on
/// the left. Maps 1:1 onto PDFView's `displaysAsBook` / `displaysRTL`
/// (docs/PDFKIT-FACTS.md §3). The default is a plain LTR non-book layout.
public struct BookLayout: Equatable, Sendable {
    /// Odd-numbered first page: index 0 stands alone, pairs are (1,2),(3,4)….
    public var displaysAsBook: Bool
    /// Right-to-left reading: the pair's left/right slots are swapped.
    public var rtl: Bool

    public init(displaysAsBook: Bool = false, rtl: Bool = false) {
        self.displaysAsBook = displaysAsBook
        self.rtl = rtl
    }

    /// Plain left-to-right, non-book layout (pairs 0,1 | 2,3 | …).
    public static let `default` = BookLayout(displaysAsBook: false, rtl: false)
}

/// Layout constants shared by every mode.
///
/// `margin` is the single uniform ON-SCREEN margin (in VIEW POINTS) from which
/// all gaps and outer margins are derived: the gap between adjacent pages, the
/// inner gutter of a two-up spread, and the space between the outermost page
/// and the viewport edge are all this same value at a mode's standard fit.
/// `ViewModePlanner` converts it into the page-space `pageBreakMargins` inset
/// for the current scale (see `ViewModePlanner.marginInset`).
public enum ReaderLayout {
    /// The one uniform on-screen margin, in view points.
    public static let margin: CGFloat = 8
}
