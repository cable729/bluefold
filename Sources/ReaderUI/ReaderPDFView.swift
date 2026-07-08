#if os(macOS)
import AppKit
import PDFKit
import ReaderCore

/// Where an internal link points, resolved to session-model terms.
struct LinkTarget: Equatable {
    var entry: NavEntry
    /// Set when the link leads into a different PDF (PDFActionRemoteGoTo).
    var remoteFileURL: URL?
}

/// PDFView subclass that intercepts clicks on link annotations.
///
/// PDFKit's `PDFViewDelegate.pdfViewWillClick(onLink:with:)` fires only for
/// URL actions — internal GoTo links never reach it — so link handling that
/// wants history pushes and ⌘-click-to-new-tab must intercept `mouseDown`.
/// External URL links are left to PDFView's default handling.
final class ReaderPDFView: PDFView {
    /// Called for clicks on internal links (same document or another PDF).
    /// `current` is the position before the jump — the history push target.
    /// The handler performs the navigation; the click is swallowed.
    var onLinkActivated: ((_ target: LinkTarget, _ current: NavEntry, _ inNewTab: Bool) -> Void)?

    /// Left/right arrows page-turn in every display mode. PDFView pages on
    /// arrows in single-page mode but scrolls (or beeps) in the continuous
    /// modes; intercepting here makes the behavior uniform, matching Preview.
    /// Only bare arrows are taken — modified arrows (⇧ selection, ⌘ etc.)
    /// keep PDFView's behavior, and text fields are their own responder so
    /// typing is unaffected.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty,
           let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            switch Int(scalar.value) {
            case NSRightArrowFunctionKey:
                if canGoToNextPage { goToNextPage(nil) }
                return  // consume even at the last page (no beep/side-scroll)
            case NSLeftArrowFunctionKey:
                if canGoToPreviousPage { goToPreviousPage(nil) }
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let target = linkTarget(atViewPoint: viewPoint), let onLinkActivated {
            let inNewTab = event.modifierFlags.contains(.command)
            onLinkActivated(target, currentNavEntry(), inNewTab)
            return
        }
        super.mouseDown(with: event)
    }

    /// The current reading position in session-model terms.
    func currentNavEntry() -> NavEntry {
        guard
            let document,
            let destination = currentDestination,
            let page = destination.page
        else {
            return NavEntry(pageIndex: 0, scaleFactor: scaleFactor)
        }
        var point: CGPoint? = destination.point
        if destination.point.x == kPDFDestinationUnspecifiedValue
            || destination.point.y == kPDFDestinationUnspecifiedValue {
            point = nil
        }
        return NavEntry(
            pageIndex: document.index(for: page),
            point: point,
            scaleFactor: scaleFactor
        )
    }

    func go(to entry: NavEntry, in document: PDFDocument) {
        guard let page = document.page(at: min(entry.pageIndex, max(0, document.pageCount - 1)))
        else { return }
        let point = entry.point ?? CGPoint(
            x: kPDFDestinationUnspecifiedValue,
            y: kPDFDestinationUnspecifiedValue
        )
        go(to: PDFDestination(page: page, at: point))
    }

    private func linkTarget(atViewPoint viewPoint: CGPoint) -> LinkTarget? {
        guard
            let page = page(for: viewPoint, nearest: false),
            let annotation = page.annotation(at: convert(viewPoint, to: page)),
            let document
        else { return nil }
        return Self.resolveTarget(of: annotation, in: document)
    }

    /// Resolves a link annotation to its target. Internal so tests can drive
    /// it with constructed annotations instead of synthetic clicks.
    static func resolveTarget(of annotation: PDFAnnotation, in document: PDFDocument) -> LinkTarget? {
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
            // LaTeX/hyperref output often carries a bare destination with no
            // action object at all.
            if let destination = annotation.destination {
                return target(for: destination, in: document)
            }
            return nil
        }
    }

    private static func target(for destination: PDFDestination, in document: PDFDocument) -> LinkTarget? {
        guard let page = destination.page else { return nil }
        return LinkTarget(
            entry: NavEntry(
                pageIndex: document.index(for: page),
                point: normalize(destination.point)
            ),
            remoteFileURL: nil
        )
    }

    private static func normalize(_ point: CGPoint) -> CGPoint? {
        if point.x == kPDFDestinationUnspecifiedValue || point.y == kPDFDestinationUnspecifiedValue {
            return nil
        }
        return point
    }
}
#endif
