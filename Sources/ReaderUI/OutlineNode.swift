import PDFKit
import ReaderCore

/// Value-type snapshot of a PDF's table of contents, built once per document
/// so SwiftUI can render it without touching PDFKit objects.
public struct OutlineNode: Identifiable, Sendable {
    public let id = UUID()
    public let label: String
    public let entry: NavEntry?
    public let children: [OutlineNode]?

    @MainActor
    public static func tree(from document: PDFDocument) -> [OutlineNode] {
        guard let root = document.outlineRoot else { return [] }
        return children(of: root, in: document)
    }

    /// The deepest section whose start page is at or before `pageIndex` —
    /// "which section am I in". Nil when the outline is empty or the page
    /// precedes every section.
    public static func deepestLabel(in nodes: [OutlineNode], atOrBefore pageIndex: Int) -> String? {
        deepestPath(in: nodes, atOrBefore: pageIndex).last
    }

    /// Full ancestor path of the deepest section at or before `pageIndex`,
    /// root first — e.g. ["Chapter 1", "1A Rⁿ and Cⁿ", "Complex Numbers"].
    /// Ancestors without a destination of their own still contribute their
    /// label. Empty when the outline is empty or the page precedes every
    /// section (e.g. scanned PDFs with no outline at all).
    public static func deepestPath(in nodes: [OutlineNode], atOrBefore pageIndex: Int) -> [String] {
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
    public static func readingKey(of entry: NavEntry) -> (page: Int, offset: CGFloat) {
        (entry.pageIndex, -(entry.point?.y ?? CGFloat.greatestFiniteMagnitude))
    }

    /// Every outline destination (any depth) in reading order, with
    /// SAME-SPOT duplicates collapsed: a chapter heading and its first
    /// section often share one anchor (always, in scans with synthesized
    /// page-top points) — stepping between identical positions is an
    /// invisible no-op that wedged ⇤ at chapter starts (round 13.7).
    public static func orderedSectionEntries(in nodes: [OutlineNode]) -> [NavEntry] {
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
        entries.sort { readingKey(of: $0) < readingKey(of: $1) }

        var deduped: [NavEntry] = []
        for entry in entries {
            if let last = deduped.last {
                let a = readingKey(of: last)
                let b = readingKey(of: entry)
                if a.page == b.page, abs(a.offset - b.offset) <= 2 {
                    continue
                }
            }
            deduped.append(entry)
        }
        return deduped
    }

    /// Landing slop: after `go(to:)`, PDFKit parks the view slightly BELOW
    /// the requested anchor (page-break margins and rounding). Positions
    /// within this distance of an anchor count as standing ON it — with a
    /// strict comparison, "previous" re-selected the section just jumped to
    /// and looked dead (round 13).
    private static let sameSpotTolerance: CGFloat = 40

    /// One precomputed "where am I" stop: a section's reading-order key,
    /// full ancestor path, and node id. Built once per document so live
    /// breadcrumbs (updated while scrolling, round 15) cost a binary search
    /// per tick, not an outline walk.
    public struct SectionStop: Equatable, Sendable {
        public let page: Int
        public let offset: CGFloat
        public let path: [String]
        public let nodeID: UUID
    }

    /// Every destination-carrying node in reading order, ancestor paths
    /// included. Same-spot entries (chapter heading + its first section on
    /// one anchor) keep only the DEEPEST path — that is the label a reader
    /// standing there expects.
    public static func sectionStops(in nodes: [OutlineNode]) -> [SectionStop] {
        var stops: [SectionStop] = []
        func walk(_ nodes: [OutlineNode], ancestors: [String]) {
            for node in nodes {
                let path = ancestors + [node.label]
                if let entry = node.entry {
                    let key = readingKey(of: entry)
                    stops.append(SectionStop(
                        page: key.page, offset: key.offset,
                        path: path.filter { !$0.isEmpty }, nodeID: node.id
                    ))
                }
                walk(node.children ?? [], ancestors: path)
            }
        }
        walk(nodes, ancestors: [])
        stops.sort { ($0.page, $0.offset) < ($1.page, $1.offset) }

        var deduped: [SectionStop] = []
        for stop in stops {
            if let last = deduped.last, last.page == stop.page,
               abs(last.offset - stop.offset) <= 2 {
                if stop.path.count >= last.path.count {
                    deduped[deduped.count - 1] = stop
                }
                continue
            }
            deduped.append(stop)
        }
        return deduped
    }

    /// The stop containing `current` — the last one anchored at or before
    /// the position, with the same landing slop as section stepping. Binary
    /// search: this runs on every scroll tick.
    public static func currentStop(in stops: [SectionStop], at current: NavEntry) -> SectionStop? {
        let here = readingKey(of: current)
        var low = 0
        var high = stops.count - 1
        var result: SectionStop?
        while low <= high {
            let mid = (low + high) / 2
            let stop = stops[mid]
            if stop.page < here.page
                || (stop.page == here.page && stop.offset <= here.offset + sameSpotTolerance) {
                result = stop
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Index of the section containing `current`: the last entry anchored
    /// at or before the position (with landing slop). nil before the first.
    private static func currentSectionIndex(
        in ordered: [NavEntry], at current: NavEntry
    ) -> Int? {
        let here = readingKey(of: current)
        var result: Int?
        for (index, entry) in ordered.enumerated() {
            let key = readingKey(of: entry)
            if key.page < here.page
                || (key.page == here.page && key.offset <= here.offset + sameSpotTolerance) {
                result = index
            } else {
                break
            }
        }
        return result
    }

    /// The section after the current one (identity-based: immune to the
    /// view landing a few points off the anchor).
    public static func sectionEntry(in nodes: [OutlineNode], after current: NavEntry) -> NavEntry? {
        let ordered = orderedSectionEntries(in: nodes)
        guard let index = currentSectionIndex(in: ordered, at: current) else {
            return ordered.first  // before everything: next = first section
        }
        return index + 1 < ordered.count ? ordered[index + 1] : nil
    }

    /// Media-player "previous": deep into a section it returns to THAT
    /// section's start; standing at its start it goes to the one before.
    public static func sectionEntry(in nodes: [OutlineNode], before current: NavEntry) -> NavEntry? {
        let ordered = orderedSectionEntries(in: nodes)
        guard let index = currentSectionIndex(in: ordered, at: current) else { return nil }
        let entry = ordered[index]
        let here = readingKey(of: current)
        let key = readingKey(of: entry)
        let deepIntoSection: Bool
        if key.page < here.page {
            deepIntoSection = true
        } else if entry.point == nil {
            // Point-less section = page top with unknown geometry; its -∞
            // offset must NOT count as "you're below it" or previous would
            // re-target it forever. Same page ⇒ standing at its start.
            deepIntoSection = false
        } else {
            deepIntoSection = key.offset < here.offset - sameSpotTolerance
        }
        if deepIntoSection {
            return entry
        }
        return index > 0 ? ordered[index - 1] : nil
    }

    /// IDs of the ancestors of `targetID`, root first — the disclosure
    /// groups the sidebar must expand to reveal it (follow mode).
    public static func ancestorIDs(of targetID: UUID, in nodes: [OutlineNode]) -> [UUID] {
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
    public static func deepestNodeID(in nodes: [OutlineNode], atOrBefore pageIndex: Int) -> UUID? {
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
                // validatedPoint drops unspecified/out-of-crop points
                // (broken scans) — PDFView refuses to scroll to those.
                // The fallback is a CONCRETE crop-top point, never nil:
                // section stepping compares in-page offsets, and a nil
                // point compared as -∞ made "previous" think it was always
                // deep inside the section and re-target it forever
                // (round 13.6).
                let crop = page.bounds(for: .cropBox)
                let point = LinkResolver.validatedPoint(destination.point, on: page)
                    ?? CGPoint(x: crop.minX, y: crop.maxY)
                entry = NavEntry(
                    pageIndex: document.index(for: page),
                    point: point
                )
            }

            let kids = children(of: child, in: document)
            return OutlineNode(label: label, entry: entry, children: kids.isEmpty ? nil : kids)
        }
    }
}
