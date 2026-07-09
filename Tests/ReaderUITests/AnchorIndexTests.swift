#if os(macOS)
import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

/// A one-page PDF with REAL extractable text (CTLineDraw embeds the font) —
/// the text-detection tier needs PDFPage.string and selection geometry.
private func makeTextPDF(lines: [(text: String, y: CGFloat)]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AnchorIndexTests-\(UUID().uuidString).pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    for line in lines {
        let attributed = NSAttributedString(string: line.text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black,
        ])
        context.textPosition = CGPoint(x: 72, y: line.y)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    context.endPDFPage()
    context.closePDF()
    return url
}

@Suite("Anchor index")
@MainActor
struct AnchorIndexTests {
    @Test func detectsHeadingsInPageText() throws {
        let url = try makeTextPDF(lines: [
            ("Theorem 4.4.1 (Interior Extremum Theorem). Let f be differentiable.", 700),
            ("Some ordinary prose line about nothing in particular.", 650),
            ("5.2 definition: invariant subspace", 600),
            ("Exercise 21 in Section 5D shows how linear algebra can be used", 550),
        ])
        let document = try #require(PDFDocument(url: url))
        let index = AnchorIndex(document: document, sectionStops: [])

        let anchors = index.anchors(forPage: 0)
        #expect(anchors.count == 2)
        // Top-first (PDF y-up).
        #expect(anchors.first?.label == "Theorem 4.4.1 (Interior Extremum Theorem)")
        #expect(anchors.first?.kind == .theorem)
        #expect(anchors.last?.label == "5.2 definition: invariant subspace")
        #expect(anchors.last?.kind == .definition)
        // Geometry: the anchor point sits just above the heading line.
        let theorem = try #require(anchors.first)
        #expect(theorem.lineBounds != nil)
        #expect(abs(theorem.point.y - 712) < 12)
        #expect(theorem.source == .text)

        // Second request is served from the cache (same values).
        #expect(index.anchors(forPage: 0) == anchors)
    }

    @Test func classifiesNamedDestinationsIntoAnchors() throws {
        let url = try makePDFWithDestinations(
            pageCount: 5,
            destinations: [
                ("chapter.1", 0, CGPoint(x: 72, y: 700)),
                ("section.1.2", 1, CGPoint(x: 72, y: 500)),
                ("theorem.14.3.2", 3, CGPoint(x: 100, y: 450)),
                ("page.4", 4, CGPoint(x: 0, y: 792)),
            ]
        )
        let document = try #require(PDFDocument(url: url))
        let index = AnchorIndex(document: document, sectionStops: [])

        let theorems = index.anchors(forPage: 3)
        #expect(theorems.count == 1)
        #expect(theorems.first?.label == "Theorem 3.2")
        #expect(theorems.first?.destName == "theorem.14.3.2")
        #expect(theorems.first?.source == .namedDestination)

        // page.* names are navigation noise, not anchors.
        #expect(index.anchors(forPage: 4).isEmpty)
        #expect(index.anchors(forPage: 0).first?.label == "Chapter 1")
    }

    @Test func outlineStopsBecomeStructureAnchors() throws {
        let url = try makeTextPDF(lines: [("Plain page.", 700)])
        let document = try #require(PDFDocument(url: url))
        let stops = [
            OutlineNode.SectionStop(
                page: 0, offset: -700, path: ["Chapter 5", "5A Eigenvalues"],
                nodeID: UUID()
            )
        ]
        let index = AnchorIndex(document: document, sectionStops: stops)

        let anchors = index.anchors(forPage: 0)
        #expect(anchors.count == 1)
        // Deepest path label, depth 2 → section.
        #expect(anchors.first?.label == "5A Eigenvalues")
        #expect(anchors.first?.kind == .section)
        #expect(anchors.first?.point.y == 700)
    }
}

@Suite struct AnchorMergeTests {
    private func anchor(
        kind: AnchorKind, label: String, y: CGFloat,
        destName: String? = nil, source: Anchor.Source
    ) -> Anchor {
        Anchor(
            kind: kind, label: label, pageIndex: 0,
            point: CGPoint(x: 0, y: y),
            destName: destName, lineBounds: nil, source: source
        )
    }

    @Test func textLabelWinsAndAdoptsDestName() {
        // hyperref's anchor sits several points above the heading the text
        // tier finds — same spot, one glyph, best of both.
        let merged = AnchorIndex.merge([
            anchor(kind: .theorem, label: "Theorem 2.2.1", y: 712,
                   destName: "theorem.112.2.2.1", source: .namedDestination),
            anchor(kind: .theorem, label: "Theorem 2.2.1 (Axiom of Completeness)", y: 700,
                   source: .text),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.label == "Theorem 2.2.1 (Axiom of Completeness)")
        #expect(merged.first?.destName == "theorem.112.2.2.1")
        #expect(merged.first?.source == .text)
    }

    @Test func differentKindsNearbyBothSurvive() {
        // A section heading and the first theorem right under it.
        let merged = AnchorIndex.merge([
            anchor(kind: .section, label: "5A Invariant Subspaces", y: 710, source: .outline),
            anchor(kind: .theorem, label: "Theorem 5.1", y: 695, source: .text),
        ])
        #expect(merged.count == 2)
        // Top-first ordering.
        #expect(merged.first?.kind == .section)
    }

    @Test func structureKindsCollapseAtSameSpot() {
        // Chapter + its first section on one anchor (pathology #4) —
        // outline dedupe usually catches this; the merge backstops it.
        let merged = AnchorIndex.merge([
            anchor(kind: .chapter, label: "Chapter 5", y: 700, source: .outline),
            anchor(kind: .section, label: "Section 5.1", y: 700,
                   destName: "section.5.1", source: .namedDestination),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.source == .outline)
        #expect(merged.first?.destName == "section.5.1")
    }

    @Test func chapterAnchorsMergePerPageKeepingRicherLabel() {
        // Tu, probed: outline dest at the page top, printed "Chapter 1"
        // mid-page — one chapter, one glyph, the fuller label.
        let merged = AnchorIndex.merge([
            anchor(kind: .chapter, label: "Chapter 1:Euclidean Spaces", y: 636,
                   destName: nil, source: .outline),
            anchor(kind: .chapter, label: "Chapter 1", y: 480, source: .text),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.label == "Chapter 1:Euclidean Spaces")
        // Position from the text tier (the printed heading), which won.
        #expect(merged.first?.point.y == 480)
    }

    @Test func farApartSameKindStaysSeparate() {
        let merged = AnchorIndex.merge([
            anchor(kind: .theorem, label: "Theorem 5.1", y: 700, source: .text),
            anchor(kind: .theorem, label: "Theorem 5.2", y: 400, source: .text),
        ])
        #expect(merged.count == 2)
    }
}

@Suite("Anchor click")
@MainActor
struct AnchorClickTests {
    @Test func copiesLinkPushesHistoryAndToasts() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnchorClickTests-\(UUID().uuidString).pdf")
        try Data("not really a pdf, hashing only".utf8).write(to: fileURL)

        let model = ReaderWindowModel(provider: DocumentProvider(capacity: 3))
        let tabID = model.openTab(fileURL: fileURL)
        let anchor = Anchor(
            kind: .theorem, label: "Theorem 5.2", pageIndex: 152,
            point: CGPoint(x: 0, y: 500.5),
            destName: "theorem.1.5.2", lineBounds: nil, source: .text
        )

        // The test clobbers the user's clipboard; put it back afterward.
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }

        model.anchorClicked(anchor, tabID: tabID)
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.hasPrefix("bluefold://open?"))
        #expect(copied.contains("dest=theorem.1.5.2"))
        #expect(copied.contains("page=153"))  // 1-based in URLs
        // Round-trips through the codec.
        let copiedURL = try #require(URL(string: copied))
        let link = try #require(DeepLink(url: copiedURL))
        #expect(link.destination == "theorem.1.5.2")
        #expect(link.pageIndex == 152)

        // The anchor became a back-target (⌘[ returns to it) and the
        // toast confirms.
        #expect(model.tabs.first?.history.back.last == anchor.entry)
        #expect(model.toast?.text == "Link copied — Theorem 5.2")

        // ⌥: markdown form for notes.
        model.anchorClicked(anchor, tabID: tabID, asMarkdown: true)
        #expect(pasteboard.string(forType: .string)?
            .hasPrefix("[Theorem 5.2](bluefold://open?") == true)
    }
}
#endif
