import CoreGraphics
import PDFKit

extension ViewModePlanner {
    /// Reads the document's even/odd `BookLayout` from its PDF catalog
    /// `/PageLayout` entry. PDFKit does NOT auto-apply `/PageLayout`
    /// (docs/PDFKIT-FACTS.md §3), so we walk the public CGPDF catalog ourselves
    /// (the same access path as `NamedDestinations`). A missing key, or a
    /// document with no CGPDF backing, yields `.default`.
    public static func bookLayout(of document: PDFDocument) -> BookLayout {
        guard
            let cg = document.documentRef,
            let catalog = cg.catalog
        else { return .default }

        var namePtr: UnsafePointer<Int8>?
        guard
            CGPDFDictionaryGetName(catalog, "PageLayout", &namePtr),
            let namePtr
        else { return .default }

        return bookLayout(pageLayoutName: String(cString: namePtr))
    }
}
