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
