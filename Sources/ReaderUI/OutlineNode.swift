#if os(macOS)
import PDFKit
import ReaderCore

/// Value-type snapshot of a PDF's table of contents, built once per document
/// so SwiftUI can render it without touching PDFKit objects.
struct OutlineNode: Identifiable {
    let id = UUID()
    let label: String
    let entry: NavEntry?
    let children: [OutlineNode]?

    @MainActor
    static func tree(from document: PDFDocument) -> [OutlineNode] {
        guard let root = document.outlineRoot else { return [] }
        return children(of: root, in: document)
    }

    /// The deepest section whose start page is at or before `pageIndex` —
    /// "which section am I in". Nil when the outline is empty or the page
    /// precedes every section.
    static func deepestLabel(in nodes: [OutlineNode], atOrBefore pageIndex: Int) -> String? {
        deepestPath(in: nodes, atOrBefore: pageIndex).last
    }

    /// Full ancestor path of the deepest section at or before `pageIndex`,
    /// root first — e.g. ["Chapter 1", "1A Rⁿ and Cⁿ", "Complex Numbers"].
    /// Ancestors without a destination of their own still contribute their
    /// label. Empty when the outline is empty or the page precedes every
    /// section (e.g. scanned PDFs with no outline at all).
    static func deepestPath(in nodes: [OutlineNode], atOrBefore pageIndex: Int) -> [String] {
        var best: (path: [String], page: Int)?
        func walk(_ nodes: [OutlineNode], ancestors: [String]) {
            for node in nodes {
                let path = ancestors + [node.label]
                if let page = node.entry?.pageIndex, page <= pageIndex,
                   best == nil || page >= best!.page {
                    best = (path, page)
                }
                walk(node.children ?? [], ancestors: path)
            }
        }
        walk(nodes, ancestors: [])
        return best?.path ?? []
    }

    /// Reading-order key for a destination: page first, then top-to-bottom
    /// WITHIN the page (PDF y points up, so higher y = earlier). A missing
    /// point counts as the page top. Round 10: section skips land on the
    /// section's exact anchor, not the top of its page — several sections
    /// share a page in real books.
    static func readingKey(of entry: NavEntry) -> (page: Int, offset: CGFloat) {
        (entry.pageIndex, -(entry.point?.y ?? CGFloat.greatestFiniteMagnitude))
    }

    /// Every outline destination (any depth) in reading order.
    static func orderedSectionEntries(in nodes: [OutlineNode]) -> [NavEntry] {
        var entries: [NavEntry] = []
        func walk(_ nodes: [OutlineNode]) {
            for node in nodes {
                if let entry = node.entry {
                    entries.append(entry)
                }
                walk(node.children ?? [])
            }
        }
        walk(nodes)
        return entries.sorted { readingKey(of: $0) < readingKey(of: $1) }
    }

    /// Tolerance when comparing in-page offsets: "where I am" (the view's
    /// scroll anchor) and a destination a hair away must count as the same
    /// spot, or next/previous gets stuck re-selecting the current section.
    private static let sameSpotTolerance: CGFloat = 8

    /// First section anchored after the current position.
    static func sectionEntry(in nodes: [OutlineNode], after current: NavEntry) -> NavEntry? {
        let here = readingKey(of: current)
        return orderedSectionEntries(in: nodes).first { entry in
            let key = readingKey(of: entry)
            return key.page > here.page
                || (key.page == here.page && key.offset > here.offset + sameSpotTolerance)
        }
    }

    /// Last section anchored before the current position. Standing ON a
    /// section's anchor goes to the one before it, media-player-style.
    static func sectionEntry(in nodes: [OutlineNode], before current: NavEntry) -> NavEntry? {
        let here = readingKey(of: current)
        return orderedSectionEntries(in: nodes).last { entry in
            let key = readingKey(of: entry)
            return key.page < here.page
                || (key.page == here.page && key.offset < here.offset - sameSpotTolerance)
        }
    }

    /// IDs of the ancestors of `targetID`, root first — the disclosure
    /// groups the sidebar must expand to reveal it (follow mode).
    static func ancestorIDs(of targetID: UUID, in nodes: [OutlineNode]) -> [UUID] {
        func walk(_ nodes: [OutlineNode], path: [UUID]) -> [UUID]? {
            for node in nodes {
                if node.id == targetID {
                    return path
                }
                if let children = node.children,
                   let found = walk(children, path: path + [node.id]) {
                    return found
                }
            }
            return nil
        }
        return walk(nodes, path: []) ?? []
    }

    /// Same search, returning the node id (sidebar highlight).
    static func deepestNodeID(in nodes: [OutlineNode], atOrBefore pageIndex: Int) -> UUID? {
        var best: (id: UUID, page: Int)?
        func walk(_ nodes: [OutlineNode]) {
            for node in nodes {
                if let page = node.entry?.pageIndex, page <= pageIndex,
                   best == nil || page >= best!.page {
                    best = (node.id, page)
                }
                walk(node.children ?? [])
            }
        }
        walk(nodes)
        return best?.id
    }

    @MainActor
    private static func children(of outline: PDFOutline, in document: PDFDocument) -> [OutlineNode] {
        (0..<outline.numberOfChildren).compactMap { index in
            guard let child = outline.child(at: index) else { return nil }
            let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var entry: NavEntry?
            if let destination = child.destination, let page = destination.page {
                var point: CGPoint? = destination.point
                if destination.point.x == kPDFDestinationUnspecifiedValue
                    || destination.point.y == kPDFDestinationUnspecifiedValue {
                    point = nil
                }
                entry = NavEntry(pageIndex: document.index(for: page), point: point)
            }

            let kids = children(of: child, in: document)
            return OutlineNode(label: label, entry: entry, children: kids.isEmpty ? nil : kids)
        }
    }
}
#endif
