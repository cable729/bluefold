#if os(macOS)
import Foundation
import PDFKit
import ReaderCore

/// A linkable position with a human label — what a margin glyph points at.
struct Anchor: Equatable {
    /// Merge preference, low → high: a text-detected label (the book's own
    /// words) beats an outline label, which beats a name guessed from a
    /// hyperref destination ("Theorem 2.2.1").
    enum Source: Int, Comparable {
        case namedDestination = 1
        case outline = 2
        case text = 3

        static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var kind: AnchorKind
    var label: String
    var pageIndex: Int
    /// Page-space anchor point (top of the target), always inside the crop
    /// box — glyph placement and the copied link both use it.
    var point: CGPoint
    /// PDF named destination, when one exists at this spot — the durable
    /// `dest=` deep-link form.
    var destName: String?
    /// The heading line's box (text tier only) — the hover extent outline.
    var lineBounds: CGRect?
    var source: Source

    var entry: NavEntry {
        NavEntry(pageIndex: pageIndex, point: point)
    }
}

/// Per-document anchor lookup, merged from three tiers (probed 2026-07-08 —
/// no single tier covers real books):
///  - outline stops: chapters/sections, every book with a TOC (incl. scans),
///  - named destinations: durable link names; coverage varies wildly
///    (Axler has no theorem names, Tu has none at all),
///  - text detection: theorem/definition/example headings from page text —
///    the only tier that finds theorems in most books. Lazy per page.
@MainActor
final class AnchorIndex {
    private let document: PDFDocument
    /// Outline + named-dest anchors, grouped per page, built once.
    private let staticByPage: [Int: [Anchor]]
    private var mergedCache: [Int: [Anchor]] = [:]

    /// Anchors within this vertical distance and of the same kind family
    /// are one spot: a hyperref anchor sits several points above the
    /// heading baseline the text tier finds.
    private nonisolated static let mergeTolerance: CGFloat = 24
    /// Cross-family tolerance — only true same-spot duplicates collapse
    /// (chapter + its first section share one anchor, pathology #4).
    private nonisolated static let strictTolerance: CGFloat = 3
    /// Runaway guard for pathological pages (dense indexes).
    private static let maxTextAnchorsPerPage = 40

    init(document: PDFDocument, sectionStops: [OutlineNode.SectionStop]) {
        self.document = document

        var byPage: [Int: [Anchor]] = [:]
        for stop in sectionStops {
            guard let label = stop.path.last, !label.isEmpty else { continue }
            let kind: AnchorKind = switch stop.path.count {
            case 1: .chapter
            case 2: .section
            default: .subsection
            }
            byPage[stop.page, default: []].append(Anchor(
                kind: kind,
                label: label,
                pageIndex: stop.page,
                point: CGPoint(x: 0, y: -stop.offset),  // offset is -(y)
                destName: nil,
                lineBounds: nil,
                source: .outline
            ))
        }

        for (name, target) in NamedDestinations.all(in: document) {
            guard
                let heading = AnchorHeadingParser.classifyDestination(name),
                let page = document.page(at: target.pageIndex),
                let rawPoint = target.point,
                let point = LinkResolver.validatedPoint(rawPoint, on: page)
            else { continue }  // garbage/missing points can't be placed
            byPage[target.pageIndex, default: []].append(Anchor(
                kind: heading.kind,
                label: heading.label,
                pageIndex: target.pageIndex,
                point: point,
                destName: name,
                lineBounds: nil,
                source: .namedDestination
            ))
        }

        staticByPage = byPage
    }

    /// All anchors of a page, top-to-bottom, merged and deduped. The text
    /// tier runs on first request per page (a single page's text — cheap).
    func anchors(forPage pageIndex: Int) -> [Anchor] {
        if let cached = mergedCache[pageIndex] { return cached }
        let candidates = (staticByPage[pageIndex] ?? []) + textAnchors(onPage: pageIndex)
        let merged = Self.merge(candidates)
        mergedCache[pageIndex] = merged
        return merged
    }

    // MARK: - Merging

    /// Highest-preference anchor wins each spot; a named destination at a
    /// spot survives as the winner's `destName` (durable links with the
    /// book's own label).
    nonisolated static func merge(_ candidates: [Anchor]) -> [Anchor] {
        var result: [Anchor] = []
        for anchor in candidates.sorted(by: { $0.source > $1.source }) {
            if let index = result.firstIndex(where: { sameSpot($0, anchor) }) {
                if result[index].destName == nil {
                    result[index].destName = anchor.destName
                }
                continue
            }
            result.append(anchor)
        }
        return result.sorted { $0.point.y > $1.point.y }  // PDF y-up: top first
    }

    private nonisolated static func sameSpot(_ a: Anchor, _ b: Anchor) -> Bool {
        guard a.pageIndex == b.pageIndex else { return false }
        let distance = abs(a.point.y - b.point.y)
        let sameFamily = family(a.kind) == family(b.kind)
        return distance <= (sameFamily ? mergeTolerance : strictTolerance)
    }

    /// Structure kinds merge with each other (a chapter and its first
    /// section often share one anchor). The whole theorem family is ONE
    /// merge family: books share a single hyperref counter across
    /// theorem/definition/example environments, so a destination's guessed
    /// kind is unreliable — Abbott's `theorem.35.1.3.1` is actually
    /// Definition 1.3.1, 3pt from where the text tier finds it (probed
    /// 2026-07-08). The text label wins the merge; only its glyph shows.
    private nonisolated static func family(_ kind: AnchorKind) -> Int {
        switch kind {
        case .chapter, .section, .subsection: 0
        case .theorem, .definition, .example, .exercise: 1
        case .equation: 2
        case .other: 3
        }
    }

    // MARK: - Text tier

    private func textAnchors(onPage pageIndex: Int) -> [Anchor] {
        guard
            let page = document.page(at: pageIndex),
            let text = page.string, !text.isEmpty
        else { return [] }

        let crop = page.bounds(for: .cropBox)
        var anchors: [Anchor] = []
        let ns = text as NSString
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length), options: .byLines
        ) { line, lineRange, _, stop in
            guard let line, let heading = AnchorHeadingParser.parse(line: line) else { return }
            // Geometry from the line's selection; a heading PDFKit cannot
            // select is unplaceable — skip it.
            guard
                let selection = page.selection(for: lineRange)
            else { return }
            let bounds = selection.bounds(for: page)
            guard !bounds.isEmpty else { return }
            anchors.append(Anchor(
                kind: heading.kind,
                label: heading.label,
                pageIndex: pageIndex,
                point: CGPoint(x: crop.minX, y: min(crop.maxY, bounds.maxY + 4)),
                destName: nil,
                lineBounds: bounds,
                source: .text
            ))
            if anchors.count >= Self.maxTextAnchorsPerPage {
                stop.pointee = true
            }
        }
        return anchors
    }
}
#endif
