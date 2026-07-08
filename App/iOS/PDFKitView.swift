import PDFKit
import SwiftUI
import UIKit

/// UIKit PDFView wrapper for the active tab. Exactly one of these is alive at
/// a time (enforced by ReaderView's `.id(tab.id)`): switching tabs dismantles
/// it, capturing the precise position via `currentDestination` on teardown.
struct PDFKitView: UIViewRepresentable {
    let url: URL
    let pageIndex: Int
    let destinationPoint: CGPoint?
    let onPageChange: @MainActor (Int) -> Void
    let onTeardown: @MainActor (Int, CGPoint?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange, onTeardown: onTeardown)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.usePageViewController(false)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        context.coordinator.observePageChanges(of: view)
        restorePosition(in: view)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // Tab identity is pinned via .id(tab.id); nothing to reconcile.
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        coordinator.captureState(from: uiView)
    }

    /// Restores the stored page/point with a PDFDestination. Deferred one
    /// runloop turn so it survives PDFView's initial layout pass.
    private func restorePosition(in view: PDFView) {
        guard
            let document = view.document,
            document.pageCount > 0,
            pageIndex > 0 || destinationPoint != nil,
            let page = document.page(at: min(pageIndex, document.pageCount - 1))
        else { return }
        let point =
            destinationPoint
            ?? CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)
        let destination = PDFDestination(page: page, at: point)
        DispatchQueue.main.async { [weak view] in
            view?.go(to: destination)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private let onPageChange: @MainActor (Int) -> Void
        private let onTeardown: @MainActor (Int, CGPoint?) -> Void

        init(
            onPageChange: @escaping @MainActor (Int) -> Void,
            onTeardown: @escaping @MainActor (Int, CGPoint?) -> Void
        ) {
            self.onPageChange = onPageChange
            self.onTeardown = onTeardown
        }

        func observePageChanges(of view: PDFView) {
            // Selector-based: .PDFViewPageChanged is posted on the main
            // thread, where this MainActor coordinator lives.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard
                let view = notification.object as? PDFView,
                let document = view.document,
                let page = view.currentPage
            else { return }
            onPageChange(document.index(for: page))
        }

        func captureState(from view: PDFView) {
            NotificationCenter.default.removeObserver(self)
            guard
                let document = view.document,
                let destination = view.currentDestination,
                let page = destination.page
            else { return }
            let raw = destination.point
            let point: CGPoint? =
                (raw.x == kPDFDestinationUnspecifiedValue
                    || raw.y == kPDFDestinationUnspecifiedValue) ? nil : raw
            onTeardown(document.index(for: page), point)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
