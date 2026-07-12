import CoreGraphics
import Foundation

/// Which side of the primary pane the split pane sits on (VS Code
/// Split Left / Split Right). `trailing` (right) is the historical and
/// default behavior.
public enum SplitSide: String, Codable, Equatable, Sendable {
    case leading
    case trailing
}

/// The axis the split pane divides along: `horizontal` = side-by-side
/// (left/right, the historical behavior), `vertical` = stacked (top/bottom).
/// Optional on `WindowState` so files written before this keep decoding;
/// readers treat nil as `.horizontal`.
public enum SplitAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

/// Persistable state of one reader window: geometry plus its tab strip.
public struct WindowState: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Window frame in screen coordinates; nil lets the system place it.
    public var frame: CGRect?
    public var tabs: [TabState]
    public var activeTabID: UUID?
    /// ACTIVE tab of the secondary split pane, when the window is split.
    /// Optional, so schema-1 files written before splits keep decoding.
    public var splitTabID: UUID?
    /// Side the split pane sits on. Optional so files written before sided
    /// splits keep decoding; readers treat nil as `.trailing` (the only
    /// behavior that existed when those files were written).
    public var splitSide: SplitSide?
    /// Axis the split divides along (`horizontal` = left/right, `vertical`
    /// = top/bottom). Optional; readers treat nil as `.horizontal`.
    public var splitAxis: SplitAxis?
    /// Every tab living in the split pane's own tab strip, in strip order.
    /// Optional so files written before per-pane strips keep decoding;
    /// readers treat nil as `[splitTabID]` (the single tab those files
    /// could show in the pane).
    public var splitTabIDs: [UUID]?

    public init(
        id: UUID = UUID(),
        frame: CGRect? = nil,
        tabs: [TabState] = [],
        activeTabID: UUID? = nil,
        splitTabID: UUID? = nil,
        splitSide: SplitSide? = nil,
        splitAxis: SplitAxis? = nil,
        splitTabIDs: [UUID]? = nil
    ) {
        self.id = id
        self.frame = frame
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.splitTabID = splitTabID
        self.splitSide = splitSide
        self.splitAxis = splitAxis
        self.splitTabIDs = splitTabIDs
    }
}

/// The whole app session — every window, every tab — as saved to disk and
/// restored at launch, browser-style.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var windows: [WindowState]

    public init(schemaVersion: Int = Self.currentSchemaVersion, windows: [WindowState] = []) {
        self.schemaVersion = schemaVersion
        self.windows = windows
    }
}
