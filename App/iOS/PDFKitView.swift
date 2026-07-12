import PDFKit
import ReaderCore
import ReaderUI
import SwiftUI
import UIKit

/// UIKit PDFView wrapper for the active tab. Exactly one of these is alive at
/// a time (enforced by ReaderView's `.id(...)`, which also keys on the theme
/// so theme switches rebuild the render caches): switching tabs dismantles
/// it, capturing the precise position back into the tab state.
struct PDFKitView: UIViewRepresentable {
    let tab: TabState
    let document: PDFDocument
    unowned let model: ReaderSessionModel
    let backgroundColor: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(tabID: tab.id, model: model)
    }

    func makeUIView(context: Context) -> ReaderPDFViewIOS {
        let view = ReaderPDFViewIOS()
        view.usePageViewController(false)
        view.displayMode = PDFDisplayMode(rawValue: tab.displayModeRaw) ?? .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = backgroundColor
        // System find UI (⌘F / toolbar button routes through the model).
        view.isFindInteractionEnabled = true
        view.autoScales = tab.autoScales
        if !tab.autoScales {
            view.scaleFactor = tab.scaleFactor
        }
        view.document = document

        view.onLinkActivated = { [weak model] target, current in
            model?.linkActivated(target: target, current: current)
        }

        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.observePageChanges(of: view)
        model.activeController = coordinator

        // Restore via the shared validated-point jump (a raw unspecified
        // destination point silently no-ops on some documents). Deferred one
        // runloop turn so it survives PDFView's initial layout pass.
        let restore = tab.currentNavEntry
        if restore.pageIndex > 0 || restore.point != nil {
            DispatchQueue.main.async { [weak view] in
                guard let view, let document = view.document else { return }
                view.go(to: restore, in: document)
            }
        }
        return view
    }

    func updateUIView(_ uiView: ReaderPDFViewIOS, context: Context) {
        // Tab identity is pinned via .id; nothing to reconcile.
    }

    static func dismantleUIView(_ uiView: ReaderPDFViewIOS, coordinator: Coordinator) {
        coordinator.captureNow()
        if coordinator.model?.activeController === coordinator {
            coordinator.model?.activeController = nil
        }
        uiView.onLinkActivated = nil
        uiView.document = nil
    }

    @MainActor
    final class Coordinator: NSObject, ActivePDFNavigating {
        let tabID: UUID
        weak var model: ReaderSessionModel?
        weak var view: ReaderPDFViewIOS?

        init(tabID: UUID, model: ReaderSessionModel) {
            self.tabID = tabID
            self.model = model
        }

        func observePageChanges(of view: ReaderPDFViewIOS) {
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
                let view,
                let document = view.document,
                let page = view.currentPage
            else { return }
            model?.updatePage(tabID: tabID, pageIndex: document.index(for: page))
        }

        // MARK: ActivePDFNavigating

        var liveNavEntry: NavEntry? {
            view?.currentNavEntry()
        }

        func execute(_ entry: NavEntry) {
            guard let view, let document = view.document else { return }
            view.go(to: entry, in: document)
        }

        func apply(displayMode: PDFDisplayMode) {
            view?.displayMode = displayMode
        }

        func presentFindNavigator() {
            view?.findInteraction.presentFindNavigator(showingReplace: false)
        }

        /// Persists the exact reading position back into the tab.
        func captureNow() {
            NotificationCenter.default.removeObserver(self)
            guard let view, let liveNavEntry else { return }
            model?.capture(tabID: tabID, entry: liveNavEntry, autoScales: view.autoScales)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
