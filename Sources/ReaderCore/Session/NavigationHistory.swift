import CoreGraphics
import Foundation

/// A single position in a document that navigation can return to.
public struct NavEntry: Codable, Equatable, Sendable {
    /// Zero-based page index.
    public var pageIndex: Int
    /// Top-left point of the visible area in page space, if known.
    public var point: CGPoint?
    /// View scale factor at the time of capture, if known.
    public var scaleFactor: CGFloat?

    public init(pageIndex: Int, point: CGPoint? = nil, scaleFactor: CGFloat? = nil) {
        self.pageIndex = pageIndex
        self.point = point
        self.scaleFactor = scaleFactor
    }
}

/// Browser-style per-tab navigation history.
///
/// This is the single source of truth for back/forward — the UI layer must
/// push onto it for every jump (link click, outline click, thumbnail click,
/// search-result jump) and never use PDFView's built-in history, which is
/// opaque and cannot be persisted.
public struct NavigationHistory: Codable, Equatable, Sendable {
    /// Maximum retained entries per direction; oldest back-entries are
    /// discarded beyond this.
    public static let maxEntries = 200

    public private(set) var back: [NavEntry]
    public private(set) var forward: [NavEntry]

    public init(back: [NavEntry] = [], forward: [NavEntry] = []) {
        self.back = back
        self.forward = forward
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Records `entry` (the position being navigated *away from*) as a
    /// back-target. Any forward stack is invalidated, as in a browser.
    public mutating func push(_ entry: NavEntry) {
        back.append(entry)
        forward.removeAll()
        if back.count > Self.maxEntries {
            back.removeFirst(back.count - Self.maxEntries)
        }
    }

    /// Pops the most recent back-target, pushing `current` onto the forward
    /// stack. Returns the position to navigate to, or nil if at the start.
    public mutating func goBack(from current: NavEntry) -> NavEntry? {
        guard let target = back.popLast() else { return nil }
        forward.append(current)
        return target
    }

    /// Pops the most recent forward-target, pushing `current` onto the back
    /// stack. Returns the position to navigate to, or nil if at the end.
    public mutating func goForward(from current: NavEntry) -> NavEntry? {
        guard let target = forward.popLast() else { return nil }
        back.append(current)
        return target
    }
}
