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
    unowned let model: ReaderWindowModel
    /// The primary pane owns model.activeController (navigation chrome binds
    /// to it); the split pane routes links through its own coordinator.
    var isPrimary = true

    func makeCoordinator() -> Coordinator {
        Coordinator(tabID: tab.id, model: model)
    }

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.document = document
        view.displayMode = PDFDisplayMode(rawValue: tab.displayModeRaw) ?? .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = ThemeManager.shared.pdfBackground
        view.autoScales = tab.autoScales
        if !tab.autoScales {
            view.scaleFactor = tab.scaleFactor
        }

        let coordinator = context.coordinator
        view.onLinkActivated = { [weak model, weak coordinator] target, current, inNewTab in
            model?.linkActivated(
                sourceTabID: coordinator?.tabID,
                via: coordinator,
                target: target.entry,
                remoteFileURL: target.remoteFileURL,
                current: current,
                inNewTab: inNewTab
            )
        }

        let restore = tab.currentNavEntry
        // Defer until after the view has a size, or the point lands wrong.
        DispatchQueue.main.async { [weak view] in
            guard let view, let document = view.document else { return }
            view.go(to: restore, in: document)
        }

        context.coordinator.view = view
        context.coordinator.observePageChanges(of: view)
        if isPrimary {
            model.activeController = context.coordinator
        }
        // The document is resident now: give EVERY tab of this book its
        // strip breadcrumb — restored background tabs sat as "p.N" until
        // first activated (round 10). Deferred: makeNSView runs during a
        // SwiftUI update, and mutating observable state mid-update corrupts
        // the update graph (round 12.5 intermittent weirdness).
        let model = self.model
        let url = model.url(for: tab)
        DispatchQueue.main.async {
            model.refreshBreadcrumbs(forDocumentAt: url)
        }
        return view
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {}

    static func dismantleNSView(_ view: ReaderPDFView, coordinator: Coordinator) {
        coordinator.captureNow()
        if coordinator.model?.activeController === coordinator {
            coordinator.model?.activeController = nil
        }
        view.onLinkActivated = nil
        view.document = nil
    }

    @MainActor
    final class Coordinator: ActivePDFControlling {
        let tabID: UUID
        weak var model: ReaderWindowModel?
        weak var view: ReaderPDFView?
        // nonisolated(unsafe): written on main; read in deinit.
        private nonisolated(unsafe) var pageObserver: NSObjectProtocol?

        init(tabID: UUID, model: ReaderWindowModel) {
            self.tabID = tabID
            self.model = model
        }

        deinit {
            if let pageObserver {
                NotificationCenter.default.removeObserver(pageObserver)
            }
        }

        /// Streams page turns into the tab state (crash-safe restore,
        /// sidebar current-section highlight). Never a history event.
        func observePageChanges(of view: ReaderPDFView) {
            pageObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard
                        let self,
                        let view = self.view,
                        let document = view.document,
                        let page = view.currentPage
                    else { return }
                    self.model?.noteCurrentPage(
                        tabID: self.tabID,
                        pageIndex: document.index(for: page)
                    )
                }
            }
        }

        // MARK: ActivePDFControlling

        var liveNavEntry: NavEntry? {
            view?.currentNavEntry()
        }

        func execute(_ entry: NavEntry) {
            guard let view, let document = view.document else { return }
            view.go(to: entry, in: document)
        }

        func showFindResults(_ matches: [PDFSelection], current: PDFSelection?) {
            guard let view else { return }
            view.highlightedSelections = matches.isEmpty ? nil : matches
            if let current {
                view.setCurrentSelection(current, animate: true)
            } else {
                view.clearSelection()
            }
        }

        func apply(displayModeRaw: Int) {
            guard let view else { return }
            view.displayMode = PDFDisplayMode(rawValue: displayModeRaw) ?? .singlePageContinuous
        }

        func fitWidth() {
            view?.autoScales = true
        }

        func fitHeight() {
            guard
                let view,
                let page = view.currentPage
            else { return }
            view.autoScales = false
            let pageHeight = page.bounds(for: view.displayBox).height
            guard pageHeight > 0 else { return }
            view.scaleFactor = view.bounds.height / pageHeight
        }

        /// PDFView's own page turns respect the display mode (a "page" is a
        /// spread in two-up modes) and scroll position in continuous modes.
        func goToPreviousPage() {
            guard let view, view.canGoToPreviousPage else { return }
            view.goToPreviousPage(nil)
        }

        func goToNextPage() {
            guard let view, view.canGoToNextPage else { return }
            view.goToNextPage(nil)
        }

        /// Persists the exact reading position back into the tab.
        func captureNow() {
            guard let view, let entry = liveNavEntry else { return }
            model?.capture(
                tabID: tabID,
                entry: entry,
                autoScales: view.autoScales,
                displayModeRaw: view.displayMode.rawValue
            )
        }
    }
}
#endif
