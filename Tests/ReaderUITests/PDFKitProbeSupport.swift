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
    ///
    /// Every caller MUST tear the returned pair down before it leaves scope —
    /// either via `withView` (which does it in a `defer`) or by a
    /// `defer { PDFKitProbe.teardown(view, window) }` at the call site. PDFKit
    /// schedules `layoutDocumentView` asynchronously (`DispatchQueue.main.async`);
    /// a block queued by this view that fires AFTER the view/window/document is
    /// gone — during a later, concurrently-running test — dereferences torn-down
    /// state and SIGSEGVs. `teardown` detaches everything and drains the runloop
    /// so those blocks fire against consistent state while we still own it.
    static func makeView(
        document: PDFDocument, viewport: CGSize, mode: PDFDisplayMode
    ) -> (PDFView, NSWindow) {
        let view = PDFView(frame: CGRect(origin: .zero, size: viewport))
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: viewport),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        // We keep our own strong ref to `window` for the test's lifetime; don't
        // let close() release it out from under us during teardown.
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.displayMode = mode
        view.document = document
        view.layoutDocumentView()
        return (view, window)
    }

    /// Create a hosted probe view, run `body` against it, and GUARANTEE teardown
    /// (even if `body` throws). The clean way to use a probe: teardown can never
    /// be forgotten. Works for any `PDFView` subclass (e.g. `ReaderPDFView`).
    @discardableResult
    static func withView<V: PDFView, T>(
        _ make: (PDFDocument, CGSize, PDFDisplayMode) -> (V, NSWindow),
        document: PDFDocument, viewport: CGSize, mode: PDFDisplayMode,
        _ body: (V, NSWindow) throws -> T
    ) rethrows -> T {
        let (view, window) = make(document, viewport, mode)
        defer { teardown(view, window) }
        return try body(view, window)
    }

    /// Overload for the default `PDFView` probe.
    @discardableResult
    static func withView<T>(
        document: PDFDocument, viewport: CGSize, mode: PDFDisplayMode,
        _ body: (PDFView, NSWindow) throws -> T
    ) rethrows -> T {
        try withView(makeView, document: document, viewport: viewport, mode: mode, body)
    }

    /// Robust teardown for an offscreen probe view. Detach the document (so any
    /// still-queued async layout touches no pages), unhook the view from its
    /// window, close the window, then DRAIN the main runloop across several turns
    /// until PDFKit's pending async `layoutDocumentView` has fully settled. This
    /// is what keeps a block queued by THIS test from firing during a LATER test
    /// after everything here is gone (the parallel-teardown SIGSEGV).
    static func teardown(_ view: PDFView, _ window: NSWindow) {
        view.document = nil
        settle(2)                    // let the detach's own queued layout fire on nil doc
        window.contentView = nil     // unhook the view from the window
        window.orderOut(nil)
        window.close()
        settle(6)                    // drain remaining PDFKit async-layout turns
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
