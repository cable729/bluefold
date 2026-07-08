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

    /// Chapter starts = the page indices of TOP-LEVEL outline entries,
    /// sorted. (Books whose top level is "Part I/II" skip by part — the
    /// outline's own idea of its coarsest division wins.)
    static func chapterStarts(in nodes: [OutlineNode]) -> [Int] {
        nodes.compactMap { $0.entry?.pageIndex }.sorted()
    }

    /// First chapter starting after `pageIndex` (status-bar "next chapter").
    static func chapterStart(in nodes: [OutlineNode], after pageIndex: Int) -> Int? {
        chapterStarts(in: nodes).first { $0 > pageIndex }
    }

    /// Last chapter starting before `pageIndex` (status-bar "previous
    /// chapter"). Standing ON a chapter's first page goes to the chapter
    /// before it, media-player-style.
    static func chapterStart(in nodes: [OutlineNode], before pageIndex: Int) -> Int? {
        chapterStarts(in: nodes).last { $0 < pageIndex }
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
