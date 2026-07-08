#if os(macOS)
import Observation
import SwiftUI

/// Which palette is showing, if any.
public enum PaletteMode: Equatable, Sendable {
    /// ⌘P / ⌘O — OPEN things: library books, collections, tags, open tabs.
    case navigate
    /// ⌘⇧O — navigate WITHIN the book: outline sections and bookmarks
    /// (VS Code go-to-symbol).
    case outline
    /// ⌘⇧P — fuzzy search over the command table.
    case commands
    /// ⌘G — jump to a page number.
    case goToPage
}

/// Ephemeral per-window UI state (sidebar, palettes, help overlay) that
/// commands need to drive but that doesn't belong in the persisted session.
/// Owned by `ReaderWindowView`, exposed to menu commands via a focused value.
@Observable
@MainActor
public final class ReaderWindowUIState {
    public var showSidebar = false
    var sidebarMode: SidebarMode = .outline
    /// Bumped so the sidebar search field grabs focus (⌘F).
    public private(set) var searchFocusToken = 0
    public var palette: PaletteMode?
    public var showHelp = false

    public init() {}

    public func openSearchSidebar() {
        showSidebar = true
        sidebarMode = .search
        searchFocusToken += 1
    }

    public func presentPalette(_ mode: PaletteMode) {
        showHelp = false
        palette = mode
    }

    public func dismissPalette() {
        palette = nil
    }
}

public extension FocusedValues {
    /// The key window's UI state, for menu commands (sidebar, palettes, help).
    @Entry var readerWindowUI: ReaderWindowUIState?
}
#endif
