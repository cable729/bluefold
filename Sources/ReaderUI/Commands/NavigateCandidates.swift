#if os(macOS)
import Foundation
import ReaderCore

/// One row the navigate palette (⌘P / ⌘O) can jump to.
struct NavigateCandidate: Identifiable, Equatable {
    enum Action: Equatable {
        case jump(NavEntry)
        case selectTab(windowID: UUID, tabID: UUID)
        /// Open a library book (by file path) as a new tab.
        case openBook(URL)
        /// Open every book of a collection (subtree included) as tabs.
        case openCollection(Int64)
        /// Open every book carrying a tag (descendant tags included) as tabs.
        case openTag(Int64)
    }

    let id: String
    /// SF Symbol name for the row's leading icon.
    let icon: String
    let title: String
    /// Breadcrumb path (outline) or location hint (tab/bookmark).
    let subtitle: String?
    let action: Action

    /// What the fuzzy matcher runs against when the title alone misses —
    /// lets "ch1 complex" find "Chapter 1 › … › Complex Numbers".
    var searchText: String {
        subtitle.map { "\($0) › \(title)" } ?? title
    }
}

/// Inputs kept as plain values so candidate assembly is unit-testable
/// without a database or PDFs.
struct TabCandidateInput {
    var windowID: UUID
    var tabID: UUID
    var title: String
    var pageIndex: Int
    /// The palette never lists the tab the user is already looking at.
    var isActive: Bool
    /// Non-nil for tabs in other windows, e.g. "other window".
    var windowLabel: String?
}

struct BookmarkCandidateInput {
    var page: Int
    var label: String?
}

/// A library book the palette can open directly (quick-open, no library
/// window). Paths come from the overlay DB's file_ref mirror.
struct BookCandidateInput {
    var title: String
    /// Display string; empty when unknown. Searchable — "dummit" must find
    /// the book titled "Abstract Algebra, 3rd Edition".
    var authors: String = ""
    /// Canonical file path (matches tab pathHints for dedup).
    var path: String
}

/// A collection or tag the palette can open as a batch of tabs.
struct GroupCandidateInput {
    var id: Int64
    var name: String
    /// Openable books inside (subtree/descendants included).
    var bookCount: Int
}

/// Assembles the two palettes' candidate lists. The order of each list is
/// what an empty query shows.
enum NavigateCandidates {
    /// OPEN palette (⌘P/⌘O): open tabs across windows, then library books,
    /// collections, and tags.
    static func assembleOpen(
        tabs: [TabCandidateInput],
        books: [BookCandidateInput] = [],
        collections: [GroupCandidateInput] = [],
        tags: [GroupCandidateInput] = [],
        openPaths: Set<String> = []
    ) -> [NavigateCandidate] {
        var out: [NavigateCandidate] = []

        for tab in tabs where !tab.isActive {
            let location = [tab.windowLabel, "p.\(tab.pageIndex + 1)"]
                .compactMap { $0 }
                .joined(separator: " — ")
            out.append(NavigateCandidate(
                id: "tab.\(tab.tabID.uuidString)",
                icon: "rectangle.on.rectangle",
                title: tab.title,
                subtitle: "Open Tab — \(location)",
                action: .selectTab(windowID: tab.windowID, tabID: tab.tabID)
            ))
        }

        // Books already open anywhere are skipped: their "Open Tab" row is
        // the better action (switch, don't duplicate).
        for book in books where !openPaths.contains(book.path) {
            out.append(NavigateCandidate(
                id: "book.\(book.path)",
                icon: "book.closed",
                title: book.title,
                // Authors in the subtitle are part of `searchText`, so
                // fuzzy matching finds books by author too.
                subtitle: book.authors.isEmpty
                    ? "Library — open in a new tab"
                    : "\(book.authors) — Library",
                action: .openBook(URL(fileURLWithPath: book.path))
            ))
        }

        for collection in collections where collection.bookCount > 0 {
            out.append(NavigateCandidate(
                id: "collection.\(collection.id)",
                icon: "folder",
                title: collection.name,
                subtitle: "Collection — \(collection.bookCount) book\(collection.bookCount == 1 ? "" : "s") as tabs",
                action: .openCollection(collection.id)
            ))
        }
        for tag in tags where tag.bookCount > 0 {
            out.append(NavigateCandidate(
                id: "tag.\(tag.id)",
                icon: "tag",
                title: tag.name,
                subtitle: "Tag — \(tag.bookCount) book\(tag.bookCount == 1 ? "" : "s") as tabs",
                action: .openTag(tag.id)
            ))
        }
        return out
    }

    /// IN-BOOK palette (⌘⇧O): bookmarks, then the flattened outline with
    /// breadcrumb paths.
    static func assembleInBook(
        outline: [OutlineNode],
        bookmarks: [BookmarkCandidateInput]
    ) -> [NavigateCandidate] {
        var out: [NavigateCandidate] = []
        for (index, bookmark) in bookmarks.enumerated() {
            out.append(NavigateCandidate(
                id: "bookmark.\(index).\(bookmark.page)",
                icon: "bookmark",
                title: bookmark.label ?? "Page \(bookmark.page + 1)",
                subtitle: "Bookmark — p.\(bookmark.page + 1)",
                action: .jump(NavEntry(pageIndex: bookmark.page))
            ))
        }
        flatten(outline, path: [], into: &out)
        return out
    }

    /// Depth-first outline walk. Nodes without a destination can't be jumped
    /// to and are skipped, but they still contribute to their children's
    /// breadcrumb path.
    private static func flatten(
        _ nodes: [OutlineNode],
        path: [String],
        into out: inout [NavigateCandidate]
    ) {
        for node in nodes {
            if let entry = node.entry, !node.label.isEmpty {
                out.append(NavigateCandidate(
                    id: "outline.\(node.id.uuidString)",
                    icon: "list.bullet",
                    title: node.label,
                    subtitle: path.isEmpty ? nil : path.joined(separator: " › "),
                    action: .jump(entry)
                ))
            }
            if let children = node.children {
                flatten(children, path: path + [node.label], into: &out)
            }
        }
    }
}
#endif
