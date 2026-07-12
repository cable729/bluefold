import PDFKit
import ReaderCore
import ReaderUI
import SwiftUI
import UIKit

/// UIKit PDFView wrapper for one on-screen tab. At most two are alive at a
/// time — the primary pane and the split pane (enforced by ReaderView's
/// `.id(...)`, which also keys on the theme so theme switches rebuild the
/// render caches): switching tabs dismantles it, capturing the precise
/// position back into the tab state.
struct PDFKitView: UIViewRepresentable {
    /// Which controller slot this view fills on the model.
    enum Pane {
        case primary
        case split
    }

    let tab: TabState
    let document: PDFDocument
    unowned let model: ReaderSessionModel
    let backgroundColor: UIColor
    var pane: Pane = .primary

    func makeCoordinator() -> Coordinator {
        Coordinator(tabID: tab.id, model: model, pane: pane)
    }

    func makeUIView(context: Context) -> ReaderPDFViewIOS {
        let view = ReaderPDFViewIOS()
        view.usePageViewController(false)
        view.displayMode = PDFDisplayMode(rawValue: tab.displayModeRaw) ?? .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = backgroundColor
        view.autoScales = tab.autoScales
        if !tab.autoScales {
            view.scaleFactor = tab.scaleFactor
        }
        // System find UI (⌘F / toolbar button routes through the model).
        view.isFindInteractionEnabled = true
        view.document = document

        let tabID = tab.id
        view.onLinkActivated = { [weak model] target, current, mode in
            model?.linkActivated(tabID: tabID, target: target, current: current, mode: mode)
        }

        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.observePositionChanges(of: view)
        switch pane {
        case .primary: model.activeController = coordinator
        case .split: model.splitController = coordinator
        }

        // Restore via the shared validated-point jump (a raw unspecified
        // destination point silently no-ops on some documents). Deferred one
        // runloop turn so it survives PDFView's initial layout pass.
        // Same-tab rebuilds (theme switch re-keys the view) restore from
        // the model's LIVE position: SwiftUI may build the replacement
        // view before dismantling the old one, so the tab's captured state
        // can be a whole reading session stale (owner-reported jump).
        let restore: NavEntry =
            if pane == .primary, tab.id == model.activeTabID,
               let live = model.livePosition {
                live
            } else {
                tab.currentNavEntry
            }
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
        if coordinator.model?.splitController === coordinator {
            coordinator.model?.splitController = nil
        }
        uiView.onLinkActivated = nil
        uiView.document = nil
    }

    @MainActor
    final class Coordinator: NSObject, ActivePDFNavigating {
        let tabID: UUID
        weak var model: ReaderSessionModel?
        weak var view: ReaderPDFViewIOS?
        private let pane: Pane
        private var scrollObservation: NSKeyValueObservation?
        private weak var scrollView: UIScrollView?
        private var scrollToTopProxy: ScrollToTopProxy?
        /// Last time a scroll tick was forwarded (throttle: the model does
        /// a binary search per note, and KVO fires every frame mid-fling).
        private var lastScrollNote: CFTimeInterval = 0

        init(tabID: UUID, model: ReaderSessionModel, pane: Pane) {
            self.tabID = tabID
            self.model = model
            self.pane = pane
        }

        func observePositionChanges(of view: ReaderPDFViewIOS) {
            // Selector-based: .PDFViewPageChanged is posted on the main
            // thread, where this MainActor coordinator lives.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
            // Scroll ticks (in-page movement never crosses a page boundary,
            // so PDFViewPageChanged alone leaves the breadcrumb and sidebar
            // follow-highlight stale between pages). KVO on the inner
            // scroll view fires on main.
            if let scrollView = view.subviews.compactMap({ $0 as? UIScrollView }).first {
                self.scrollView = scrollView
                scrollObservation = scrollView.observe(\.contentOffset) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.scrollTicked()
                    }
                }
                installScrollToTopProxy(on: scrollView)
            }
        }

        /// Status-bar scroll-to-top is a big invisible jump — record the
        /// departure point in history so back returns. The proxy forwards
        /// every other delegate call to PDFKit's own delegate.
        private func installScrollToTopProxy(on scrollView: UIScrollView) {
            guard !(scrollView.delegate is ScrollToTopProxy) else { return }
            let proxy = ScrollToTopProxy()
            proxy.original = scrollView.delegate
            proxy.onWillScrollToTop = { [weak self] in
                guard let self, let view = self.view else { return }
                self.model?.pushHistory(tabID: self.tabID, from: view.currentNavEntry())
            }
            scrollToTopProxy = proxy
            scrollView.delegate = proxy
        }

        private func scrollTicked() {
            let now = CACurrentMediaTime()
            guard now - lastScrollNote > 0.15 else { return }
            lastScrollNote = now
            notePosition()
            // PDFKit occasionally re-claims the delegate; re-wrap it.
            if let scrollView, !(scrollView.delegate is ScrollToTopProxy) {
                installScrollToTopProxy(on: scrollView)
            }
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard let view, let document = view.document,
                  let page = view.currentPage
            else { return }
            model?.noteCurrentPage(tabID: tabID, pageIndex: document.index(for: page))
            notePosition()
        }

        private func notePosition() {
            guard let view else { return }
            model?.notePosition(tabID: tabID, entry: view.currentNavEntry())
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
            guard let view, let document = view.document else { return }
            // Capture where the reader is BEFORE the mode change.
            let entry = view.currentNavEntry()
            view.displayMode = displayMode
            // Changing displayMode alone leaves the previous mode's zoom and
            // scroll offset in place — on iPad the page ends up tiny and
            // shoved into a corner. Toggling autoScales forces PDFKit to
            // recompute the fit scale for the new layout; then re-anchor to
            // the captured position once the relayout settles.
            view.autoScales = false
            view.autoScales = true
            DispatchQueue.main.async { [weak view] in
                view?.go(to: entry, in: document)
            }
        }

        func presentFindNavigator() {
            view?.findInteraction.presentFindNavigator(showingReplace: false)
        }

        func highlight(_ selection: PDFSelection?) {
            selection?.color = .systemYellow
            view?.setCurrentSelection(selection, animate: true)
        }

        func fitWidth() {
            view?.autoScales = true
        }

        func fitHeight() {
            guard let view, let page = view.currentPage else { return }
            view.autoScales = false
            let pageHeight = page.bounds(for: view.displayBox).height
            guard pageHeight > 0 else { return }
            view.scaleFactor = view.bounds.height / pageHeight
        }

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
            NotificationCenter.default.removeObserver(self)
            scrollObservation = nil
            guard let view, let liveNavEntry else { return }
            model?.capture(tabID: tabID, entry: liveNavEntry, autoScales: view.autoScales)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// UIScrollViewDelegate shim that intercepts ONLY scrollViewShouldScrollToTop
/// (to record the departure point in jump history) and forwards everything
/// else to PDFKit's own delegate untouched.
@MainActor
private final class ScrollToTopProxy: NSObject, UIScrollViewDelegate {
    /// PDFKit's delegate. `nonisolated(unsafe)`: read from the nonisolated
    /// forwarding overrides, but only ever touched on the main thread.
    nonisolated(unsafe) weak var original: UIScrollViewDelegate?
    var onWillScrollToTop: (() -> Void)?

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if original?.responds(to: aSelector) == true {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        let allowed = original?.scrollViewShouldScrollToTop?(scrollView) ?? true
        if allowed {
            onWillScrollToTop?()
        }
        return allowed
    }
}
