#if os(macOS)
import PDFKit
import ReaderCore
import SwiftUI

/// The single live `PDFView` of a window, bound to the active tab.
///
/// Use with `.id(tab.id)` so switching tabs destroys this view entirely —
/// the PDFView's tile/render caches are the real memory cost of an open PDF,
/// and destroying the view is the only reliable way to release them. On
/// teardown the exact reading position is captured back into the tab.
struct ActivePDFView: NSViewRepresentable {
    let tab: TabState
    let document: PDFDocument
    let onCapture: (_ tabID: UUID, _ entry: NavEntry, _ autoScales: Bool, _ displayModeRaw: Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(tabID: tab.id, onCapture: onCapture)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.displayMode = PDFDisplayMode(rawValue: tab.displayModeRaw) ?? .singlePageContinuous
        view.displaysPageBreaks = true
        view.autoScales = tab.autoScales
        if !tab.autoScales {
            view.scaleFactor = tab.scaleFactor
        }

        if let page = document.page(at: min(tab.pageIndex, max(0, document.pageCount - 1))) {
            let point = tab.destinationPoint ?? CGPoint(
                x: kPDFDestinationUnspecifiedValue,
                y: kPDFDestinationUnspecifiedValue
            )
            let destination = PDFDestination(page: page, at: point)
            // Defer until after the view has a size, or the point lands wrong.
            DispatchQueue.main.async { [weak view] in
                view?.go(to: destination)
            }
        }

        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.captureNow()
        // Break the strongest retain cycles explicitly; the view is gone.
        view.document = nil
    }

    @MainActor
    final class Coordinator {
        let tabID: UUID
        let onCapture: (UUID, NavEntry, Bool, Int) -> Void
        weak var view: PDFView?

        init(tabID: UUID, onCapture: @escaping (UUID, NavEntry, Bool, Int) -> Void) {
            self.tabID = tabID
            self.onCapture = onCapture
        }

        func captureNow() {
            guard
                let view,
                let document = view.document,
                let destination = view.currentDestination,
                let page = destination.page
            else { return }

            let entry = NavEntry(
                pageIndex: document.index(for: page),
                point: destination.point,
                scaleFactor: view.scaleFactor
            )
            onCapture(tabID, entry, view.autoScales, view.displayMode.rawValue)
        }
    }
}
#endif
