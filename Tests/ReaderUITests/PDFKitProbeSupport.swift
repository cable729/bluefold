#if os(macOS)
import AppKit
import PDFKit

/// Shared fixtures for the PDFKit fact probes (PDFKitFactsTests): a real
/// PDFView laid out offscreen, fed programmatically-generated PDFs, so PDFKit
/// behavior is measured — never assumed. Findings are transcribed into
/// docs/PDFKIT-FACTS.md and pinned by the assertions in the tests.
@MainActor
enum PDFKitProbe {
    /// A multi-page PDF where each page's content is a black rectangle
    /// covering the FULL media box (so any blank border seen after box
    /// changes is provably padding, not content margin).
    static func makeDocument(pageSizes: [CGSize]) -> PDFDocument {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var firstBox = CGRect(origin: .zero, size: pageSizes[0])
        let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil)!
        for size in pageSizes {
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(box)
            context.endPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    /// A PDFView hosted in an offscreen window (PDFKit lays out lazily; an
    /// unhosted view reports empty geometry), sized to `viewport`.
    static func makeView(
        document: PDFDocument, viewport: CGSize, mode: PDFDisplayMode
    ) -> (PDFView, NSWindow) {
        let view = PDFView(frame: CGRect(origin: .zero, size: viewport))
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: viewport),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = view
        view.displayMode = mode
        view.document = document
        view.layoutDocumentView()
        return (view, window)
    }

    /// PDFView relayout settles on later runloop turns — pump briefly.
    static func settle(_ turns: Int = 3) {
        for _ in 0..<turns {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    static func scrollView(in view: PDFView) -> NSScrollView? {
        func find(_ v: NSView) -> NSScrollView? {
            for sub in v.subviews {
                if let s = sub as? NSScrollView { return s }
                if let found = find(sub) { return found }
            }
            return nil
        }
        return find(view)
    }
}
#endif
