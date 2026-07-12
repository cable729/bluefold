import Foundation
import PDFKit
import ReaderCore

/// Where an internal link points, resolved to session-model terms.
public struct LinkTarget: Equatable, Sendable {
    public var entry: NavEntry
    /// Set when the link leads into a different PDF (PDFActionRemoteGoTo).
    public var remoteFileURL: URL?

    public init(entry: NavEntry, remoteFileURL: URL? = nil) {
        self.entry = entry
        self.remoteFileURL = remoteFileURL
    }
}

/// Cross-platform resolution of PDF link annotations and destination points.
///
/// Shared by macOS `ReaderPDFView.mouseDown` and the iOS link-tap gesture so
/// both platforms apply the same destination-pathology hardening (see
/// PROGRESS.md "PDFKit destination pathologies"): unspecified points and
/// points outside the page's crop box are dropped rather than handed to
/// `PDFView.go(to:)`, which silently no-ops on them.
public enum LinkResolver {
    /// Resolves a link annotation to its target, or nil for non-links.
    /// Handles `PDFActionGoTo`, `PDFActionRemoteGoTo`, and bare
    /// `annotation.destination` (LaTeX/hyperref emits those with no action
    /// object at all). External URL actions resolve to nil — they stay with
    /// PDFView's default handling.
    public static func target(of annotation: PDFAnnotation, in document: PDFDocument) -> LinkTarget? {
        switch annotation.action {
        case let action as PDFActionRemoteGoTo:
            // Destination page/point live on the action itself; the
            // destination document is a different file.
            return LinkTarget(
                entry: NavEntry(pageIndex: action.pageIndex, point: normalize(action.point)),
                remoteFileURL: action.url
            )
        case let action as PDFActionGoTo:
            return target(for: action.destination, in: document)
        default:
            if let destination = annotation.destination {
                return target(for: destination, in: document)
            }
            return nil
        }
    }

    /// Resolves a same-document destination, validating its point.
    public static func target(for destination: PDFDestination, in document: PDFDocument) -> LinkTarget? {
        guard let page = destination.page else { return nil }
        return LinkTarget(
            entry: NavEntry(
                pageIndex: document.index(for: page),
                point: validatedPoint(destination.point, on: page)
            ),
            remoteFileURL: nil
        )
    }

    /// Maps kPDFDestinationUnspecifiedValue coordinates to nil.
    public static func normalize(_ point: CGPoint) -> CGPoint? {
        if point.x == kPDFDestinationUnspecifiedValue || point.y == kPDFDestinationUnspecifiedValue {
            return nil
        }
        return point
    }

    /// A destination point usable by `PDFView.go(to:)`, or nil to jump to
    /// the page top instead. Beyond the unspecified-value markers, sloppy
    /// scans (Munkres/Pearson) carry outline and link points OUTSIDE the
    /// page's crop box — even negative — and PDFView silently refuses to
    /// scroll to them, making every outline click a no-op.
    public static func validatedPoint(_ point: CGPoint, on page: PDFPage) -> CGPoint? {
        guard let point = normalize(point) else { return nil }
        let visible = page.bounds(for: .cropBox).insetBy(dx: -12, dy: -12)
        return visible.contains(point) ? point : nil
    }
}

extension PDFView {
    /// The current reading position in session-model terms.
    public func currentNavEntry() -> NavEntry {
        guard let document else {
            return NavEntry(pageIndex: 0, scaleFactor: scaleFactor)
        }
        if let destination = currentDestination, let page = destination.page {
            return NavEntry(
                pageIndex: document.index(for: page),
                point: LinkResolver.normalize(destination.point),
                scaleFactor: scaleFactor
            )
        }
        // `currentDestination` is briefly nil mid-layout (e.g. the instant a
        // link tap fires) — falling through to page 0 made "back" jump to
        // the top of the document. The most-visible page is the honest
        // fallback: it keeps the reader on the page they were leaving.
        if let page = currentPage {
            return NavEntry(pageIndex: document.index(for: page), scaleFactor: scaleFactor)
        }
        return NavEntry(pageIndex: 0, scaleFactor: scaleFactor)
    }

    /// Navigates to a session-model entry with an EXPLICIT in-crop point.
    /// Point-less jumps synthesize a top-of-page point: both a destination
    /// with unspecified coordinates AND `go(to: page)` — which wraps one
    /// internally — are silent no-ops on macOS 26 PDFKit for some documents
    /// (rounds 12–12.5: jumps moved the model while the view stayed parked;
    /// only explicit in-crop points always scroll).
    public func go(to entry: NavEntry, in document: PDFDocument) {
        guard let page = document.page(at: min(entry.pageIndex, max(0, document.pageCount - 1)))
        else { return }
        let crop = page.bounds(for: .cropBox)
        let point = entry.point ?? CGPoint(x: crop.minX, y: crop.maxY)
        go(to: PDFDestination(page: page, at: point))
    }
}
