import CoreGraphics
import Foundation

/// The complete, lightweight, persistable state of one tab.
///
/// A tab deliberately does NOT own a live PDF document or view — those are
/// scarce resources managed by the UI layer's document provider. Everything
/// needed to recreate the tab's exact view (file, position, zoom, history)
/// lives here, so background tabs cost only a few hundred bytes.
public struct TabState: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID

    /// Bookmark data resolving to the PDF file (survives moves/renames).
    /// Security-scoped on sandboxed platforms (iOS); plain on macOS.
    public var fileBookmark: Data?
    /// Last known file path — for display, and for recovery when the
    /// bookmark fails to resolve.
    public var pathHint: String

    /// Zero-based current page index (updated continuously for crash-safe
    /// restore; distinct from history entries).
    public var pageIndex: Int
    /// Top-left of the visible area in page space, if known.
    public var destinationPoint: CGPoint?
    public var scaleFactor: CGFloat
    public var autoScales: Bool
    /// Raw value of PDFDisplayMode (stored raw so ReaderCore stays PDFKit-free).
    public var displayModeRaw: Int

    /// Whether margins are trimmed: each page's cropBox is cropped to its
    /// printed content box (a real crop, orthogonal to zoom — TRIM-1..7).
    /// Persisted per tab; older session files predate the key and default to
    /// `false` via the hand-rolled decoder below.
    public var trimMargins: Bool

    /// Outline breadcrumb of the current position ("Ch 1 › 1A"), for the
    /// tab strip's second row. PERSISTED: recomputing needs the live
    /// document, and background tabs must never load one — without this,
    /// every relaunch showed "p.N" until a tab was activated. Optional so
    /// older session files keep decoding.
    public var breadcrumb: String?

    public var history: NavigationHistory

    public init(
        id: UUID = UUID(),
        fileBookmark: Data? = nil,
        pathHint: String,
        pageIndex: Int = 0,
        destinationPoint: CGPoint? = nil,
        scaleFactor: CGFloat = 1.0,
        autoScales: Bool = true,
        displayModeRaw: Int = 1,
        trimMargins: Bool = false,
        breadcrumb: String? = nil,
        history: NavigationHistory = NavigationHistory()
    ) {
        self.id = id
        self.fileBookmark = fileBookmark
        self.pathHint = pathHint
        self.pageIndex = pageIndex
        self.destinationPoint = destinationPoint
        self.scaleFactor = scaleFactor
        self.autoScales = autoScales
        self.displayModeRaw = displayModeRaw
        self.trimMargins = trimMargins
        self.breadcrumb = breadcrumb
        self.history = history
    }

    // Hand-rolled decode so `trimMargins` (added in Phase 7) defaults to false
    // when absent — older session files predate the key and must keep loading.
    // Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileBookmark = try c.decodeIfPresent(Data.self, forKey: .fileBookmark)
        pathHint = try c.decode(String.self, forKey: .pathHint)
        pageIndex = try c.decode(Int.self, forKey: .pageIndex)
        destinationPoint = try c.decodeIfPresent(CGPoint.self, forKey: .destinationPoint)
        scaleFactor = try c.decode(CGFloat.self, forKey: .scaleFactor)
        autoScales = try c.decode(Bool.self, forKey: .autoScales)
        displayModeRaw = try c.decode(Int.self, forKey: .displayModeRaw)
        trimMargins = try c.decodeIfPresent(Bool.self, forKey: .trimMargins) ?? false
        breadcrumb = try c.decodeIfPresent(String.self, forKey: .breadcrumb)
        history = try c.decode(NavigationHistory.self, forKey: .history)
    }

    /// The tab's current position as a history entry.
    public var currentNavEntry: NavEntry {
        NavEntry(pageIndex: pageIndex, point: destinationPoint, scaleFactor: scaleFactor)
    }

    /// Applies a navigation target to the tab's position fields.
    public mutating func apply(_ entry: NavEntry) {
        pageIndex = entry.pageIndex
        destinationPoint = entry.point
        if let scale = entry.scaleFactor {
            scaleFactor = scale
        }
    }
}
