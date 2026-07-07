#if os(macOS)
import PDFKit
import SwiftUI

/// SwiftUI wrapper around PDFKit's PDFView.
///
/// Deliberately dumb in M5: it displays one document. Tab lifecycle,
/// link interception, and state capture arrive in M6/M7 via a PDFView
/// subclass and a document provider.
public struct PDFKitView: NSViewRepresentable {
    private let document: PDFDocument?

    public init(document: PDFDocument?) {
        self.document = document
    }

    public func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        return view
    }

    public func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}
#endif
