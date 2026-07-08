import Foundation
import ReaderPersistence

/// How the library's detail area renders (round-7 owner request).
public enum LibraryViewMode: String, CaseIterable, Sendable {
    /// The classic cover grid.
    case grid
    /// Sortable rows: title, author, date added, last read.
    case list
    /// Inside a tag scope, the cover grid grouped under sub-tag headings.
    /// Anywhere else it gracefully renders as the plain grid.
    case sectioned
}

/// One row of the library list view. A plain value snapshot (see the
/// `filteredItems` performance note: view data is STORED state, recomputed
/// only when items / filter / search / sort change — never per body pass).
public struct LibraryListRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Display string ("Jane Doe, John Smith"); empty when unknown.
    public let authors: String
    /// When the book entered the library (Calibre's timestamp, or the
    /// import time for the app's own PDFs).
    public let addedAt: Date?
    /// Last reading_state touch, from `LibraryStore.lastReadTimes()`.
    public let lastReadAt: Date?

    /// Non-optional sort keys (`Date?` is not Comparable): books without a
    /// date sort before everything in ascending order.
    public var addedSortKey: Date { addedAt ?? .distantPast }
    public var lastReadSortKey: Date { lastReadAt ?? .distantPast }

    public static let defaultSortOrder = [
        KeyPathComparator(\LibraryListRow.title)
    ]
}

/// One heading plus its books in the sectioned-by-tag view.
public struct LibraryTagSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let items: [LibraryItem]

    public init(id: String, title: String, items: [LibraryItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

extension LibraryModel {
    /// What the detail area actually renders: `.sectioned` only means
    /// something inside a tag scope — anywhere else it falls back to the
    /// grid (the toggle keeps its state for the next tag click).
    public var effectiveViewMode: LibraryViewMode {
        if viewMode == .sectioned {
            if case .tag = filter { return .sectioned }
            return .grid
        }
        return viewMode
    }

    /// Rebuilds the stored per-mode view data from `filteredItems`. Pure
    /// in-memory work — called whenever the filtered list changes.
    func rebuildDerivedViewData() {
        listRows = filteredItems.map { item in
            LibraryListRow(
                id: item.id,
                title: item.title,
                authors: item.authors.joined(separator: ", "),
                addedAt: item.addedAt,
                lastReadAt: lastReadByItemID[item.id]
            )
        }
        .sorted(using: listSortOrder)

        if case .tag(let tagID) = filter {
            tagSections = Self.tagSections(
                scopeTagID: tagID, tagTree: tagTree,
                items: filteredItems, itemTags: itemTags
            )
        } else {
            tagSections = []
        }
    }

    /// Groups a tag scope's (already filtered) items under headings: books
    /// carrying ONLY the scope tag first, then one section per child tag in
    /// tag order (the owner's round-7 sketch). Books tagged deeper in the
    /// hierarchy roll up into their direct child's section; a book tagged
    /// under several children appears in each (tags are many-to-many).
    /// Empty sections are dropped. Pure, for direct testing.
    static func tagSections(
        scopeTagID: Int64,
        tagTree: [TagNode],
        items: [LibraryItem],
        itemTags: [String: [TagRecord]]
    ) -> [LibraryTagSection] {
        guard let scope = findTag(scopeTagID, in: tagTree) else { return [] }

        // Every tag id inside a child's subtree maps to that child's
        // position — descendants roll up into their direct child section.
        var childIndexByTagID: [Int64: Int] = [:]
        func register(_ node: TagNode, under childIndex: Int) {
            if let id = node.tag.id {
                childIndexByTagID[id] = childIndex
            }
            for grandchild in node.children {
                register(grandchild, under: childIndex)
            }
        }
        for (index, child) in scope.children.enumerated() {
            register(child, under: index)
        }

        var scopeOnly: [LibraryItem] = []
        var perChild: [[LibraryItem]] = Array(repeating: [], count: scope.children.count)
        for item in items {
            let childIndexes = Set(
                (itemTags[item.id] ?? []).compactMap { tag in
                    tag.id.flatMap { childIndexByTagID[$0] }
                }
            )
            if childIndexes.isEmpty {
                // In scope but under no child: tagged with the scope tag
                // itself only.
                scopeOnly.append(item)
            } else {
                for index in childIndexes.sorted() {
                    perChild[index].append(item)
                }
            }
        }

        var sections: [LibraryTagSection] = []
        if !scopeOnly.isEmpty {
            sections.append(
                LibraryTagSection(
                    id: "scope-\(scopeTagID)", title: scope.tag.name, items: scopeOnly
                )
            )
        }
        for (index, child) in scope.children.enumerated() where !perChild[index].isEmpty {
            sections.append(
                LibraryTagSection(
                    id: "tag-\(child.tag.id ?? -1)", title: child.tag.name,
                    items: perChild[index]
                )
            )
        }
        return sections
    }

    private static func findTag(_ id: Int64, in nodes: [TagNode]) -> TagNode? {
        for node in nodes {
            if node.tag.id == id { return node }
            if let found = findTag(id, in: node.children) { return found }
        }
        return nil
    }

    // MARK: - View-preference persistence

    private static let viewModeKey = "LibraryViewMode"
    private static let listSortKey = "LibraryListSort"

    /// Restores view mode + list sort from UserDefaults. Only the real app
    /// calls this (tests stay on the deterministic defaults).
    func loadViewPreferences() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.viewModeKey),
            let mode = LibraryViewMode(rawValue: raw)
        {
            viewMode = mode
        }
        if let raw = defaults.string(forKey: Self.listSortKey),
            let order = Self.sortOrder(fromPersisted: raw)
        {
            listSortOrder = order
        }
    }

    func persistViewPreferences() {
        guard persistsViewPreferences else { return }
        let defaults = UserDefaults.standard
        defaults.set(viewMode.rawValue, forKey: Self.viewModeKey)
        defaults.set(Self.persistedString(from: listSortOrder), forKey: Self.listSortKey)
    }

    /// Encodes a sort order as `"column:direction,…"` — KeyPathComparator
    /// itself isn't serializable.
    static func persistedString(from order: [KeyPathComparator<LibraryListRow>]) -> String {
        order.compactMap { comparator -> String? in
            let column: String?
            if comparator.keyPath == \LibraryListRow.title {
                column = "title"
            } else if comparator.keyPath == \LibraryListRow.authors {
                column = "authors"
            } else if comparator.keyPath == \LibraryListRow.addedSortKey {
                column = "added"
            } else if comparator.keyPath == \LibraryListRow.lastReadSortKey {
                column = "lastRead"
            } else {
                column = nil
            }
            guard let column else { return nil }
            return "\(column):\(comparator.order == .reverse ? "reverse" : "forward")"
        }
        .joined(separator: ",")
    }

    static func sortOrder(fromPersisted raw: String) -> [KeyPathComparator<LibraryListRow>]? {
        let comparators = raw.split(separator: ",").compactMap {
            token -> KeyPathComparator<LibraryListRow>? in
            let parts = token.split(separator: ":")
            guard parts.count == 2 else { return nil }
            let order: SortOrder = parts[1] == "reverse" ? .reverse : .forward
            switch parts[0] {
            case "title": return KeyPathComparator(\.title, order: order)
            case "authors": return KeyPathComparator(\.authors, order: order)
            case "added": return KeyPathComparator(\.addedSortKey, order: order)
            case "lastRead": return KeyPathComparator(\.lastReadSortKey, order: order)
            default: return nil
            }
        }
        return comparators.isEmpty ? nil : comparators
    }
}
