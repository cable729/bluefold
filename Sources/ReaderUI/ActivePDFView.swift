#if os(macOS)
import Dependencies
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
        // Margin anchors: the provider must be in place before the document
        // is assigned or PDFKit never asks for overlays on the first pages.
        let anchorProvider = AnchorOverlayProvider()
        anchorProvider.index = model.anchorIndex(for: document)
        let clickTabID = tab.id
        anchorProvider.onAnchorClicked = { [weak model] anchor, modifiers in
            guard let model else { return }
            model.focusPane(containingTab: clickTabID)
            model.anchorClicked(
                anchor, tabID: clickTabID, asMarkdown: modifiers.contains(.option)
            )
        }
        context.coordinator.anchorProvider = anchorProvider
        anchorProvider.isEnabled = AppSettings.shared.marginAnchorsEnabled
        view.pageOverlayViewProvider = anchorProvider
        view.document = document
        // Recolor the PDF's own link boxes to the theme secondary before the
        // first render. This view is `.id`'d on the theme, so it rebuilds on
        // a theme change and re-tints; the colorizer caches per color, so a
        // plain tab switch doesn't re-walk the document.
        LinkBoxColorizer.apply(ThemeManager.shared.linkBox, to: document)
        view.displayMode = PDFDisplayMode(rawValue: tab.displayModeRaw) ?? .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = ThemeManager.shared.pdfBackground
        // On a theme switch the view's `.id` changes, so SwiftUI destroys and
        // rebuilds this view — and it often builds the replacement BEFORE
        // tearing down the outgoing one (whose teardown is what captures the
        // live zoom/position into the tab). Restore from that outgoing view's
        // LIVE state when it's still attached, so a theme switch preserves the
        // exact zoom instead of snapping back to stale tab state.
        let pane = isPrimary ? model.primaryController : model.splitController
        // Only when the outgoing view is the SAME tab (theme rebuild), never a
        // different tab (tab switch), whose position must NOT leak in.
        let outgoing = pane?.controlledTabID == tab.id ? pane : nil
        let live = outgoing?.liveNavEntry
        let restore = live ?? tab.currentNavEntry
        let restoreAutoScales = live != nil ? outgoing!.liveAutoScales : tab.autoScales
        view.autoScales = restoreAutoScales
        if !restoreAutoScales {
            view.scaleFactor = restore.scaleFactor ?? tab.scaleFactor
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
        view.onLinkSplit = { [weak model, weak coordinator] target, axis in
            model?.linkActivatedSplit(
                sourceTabID: coordinator?.tabID,
                target: target.entry,
                remoteFileURL: target.remoteFileURL,
                axis: axis
            )
        }

        // Defer until after the view has a size, or the point lands wrong.
        DispatchQueue.main.async { [weak view] in
            guard let view, let document = view.document else { return }
            view.go(to: restore, in: document)
        }

        // Clicking a pane focuses it — sidebar, status bar, and commands
        // follow the focused pane (round-14 split semantics). Deferred one
        // hop: focusPane mutates observable state (see the note below).
        let tabID = tab.id
        view.onInteract = { [weak model] in
            DispatchQueue.main.async { model?.focusPane(containingTab: tabID) }
        }

        context.coordinator.view = view
        context.coordinator.observePageChanges(of: view)
        context.coordinator.observeScrolling(of: view)
        if isPrimary {
            model.primaryController = context.coordinator
        } else {
            model.splitController = context.coordinator
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

    func updateNSView(_ view: ReaderPDFView, context: Context) {
        // Reading the observable here registers the dependency: toggling
        // the setting in the Settings window re-runs this update in every
        // visible pane.
        context.coordinator.anchorProvider?.isEnabled =
            AppSettings.shared.marginAnchorsEnabled
        view.hoverPreviewEnabled = AppSettings.shared.linkHoverPreviewEnabled
    }

    static func dismantleNSView(_ view: ReaderPDFView, coordinator: Coordinator) {
        view.cancelLinkHover()
        coordinator.captureNow()
        if coordinator.model?.primaryController === coordinator {
            coordinator.model?.primaryController = nil
        }
        if coordinator.model?.splitController === coordinator {
            coordinator.model?.splitController = nil
        }
        view.onLinkActivated = nil
        view.onLinkSplit = nil
        view.onInteract = nil
        view.pageOverlayViewProvider = nil
        view.document = nil
    }

    @MainActor
    final class Coordinator: ActivePDFControlling {
        let tabID: UUID
        weak var model: ReaderWindowModel?
        weak var view: ReaderPDFView?
        @Dependency(\.appLogger) private var log
        /// Strong: PDFView holds its overlay provider weakly.
        var anchorProvider: AnchorOverlayProvider?
        // nonisolated(unsafe): written on main; read in deinit.
        private nonisolated(unsafe) var pageObserver: NSObjectProtocol?
        private nonisolated(unsafe) var scrollObserver: NSObjectProtocol?
        /// Trailing throttle for live-position updates (round 15: the strip
        /// breadcrumb and sidebar highlight follow the scroll, ~12 Hz max —
        /// each tick is a binary search over precomputed section stops).
        private var livePositionScheduled = false

        init(tabID: UUID, model: ReaderWindowModel) {
            self.tabID = tabID
            self.model = model
        }

        deinit {
            if let pageObserver {
                NotificationCenter.default.removeObserver(pageObserver)
            }
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        /// Streams page turns into the tab state (crash-safe restore,
        /// reading-state persistence). Never a history event.
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

        /// Live section tracking while scrolling: PDFViewPageChanged only
        /// fires on page flips, so within-page section changes (and books
        /// with several sections per page) looked frozen until scroll
        /// settled. Observes the internal scroll view's bounds instead.
        func observeScrolling(of view: ReaderPDFView) {
            guard let scrollView = Self.firstScrollView(in: view) else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleLivePositionUpdate() }
            }
        }

        private func scheduleLivePositionUpdate() {
            guard !livePositionScheduled else { return }
            livePositionScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                self.livePositionScheduled = false
                guard let entry = self.liveNavEntry else { return }
                self.model?.noteLivePosition(tabID: self.tabID, entry: entry)
            }
        }

        private static func firstScrollView(in view: NSView) -> NSScrollView? {
            for subview in view.subviews {
                if let scroll = subview as? NSScrollView { return scroll }
                if let found = firstScrollView(in: subview) { return found }
            }
            return nil
        }

        // MARK: ActivePDFControlling

        var liveNavEntry: NavEntry? {
            view?.currentNavEntry()
        }

        var liveAutoScales: Bool {
            view?.autoScales ?? false
        }

        var controlledTabID: UUID { tabID }

        var selectionNavEntry: NavEntry? {
            guard
                let view,
                let document = view.document,
                let selection = view.currentSelection,
                let page = selection.pages.first,
                selection.string?.isEmpty == false
            else { return nil }
            let bounds = selection.bounds(for: page)
            return NavEntry(
                pageIndex: document.index(for: page),
                point: CGPoint(x: bounds.minX, y: bounds.maxY),
                scaleFactor: view.scaleFactor
            )
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

        /// Realizes a standard-fit `LayoutPlan` (from `ViewModePlanner`) on the
        /// live view: page-break insets, explicit scale, deferred re-centering.
        /// Toolbar/button wiring stays in a later phase — this is the applier
        /// those callers will route through.
        func applyLayoutPlan(_ plan: LayoutPlan) {
            guard let view else { return }
            LayoutApplier.apply(plan, to: view, log: log)
        }

        /// Applies a view-mode button / mode switch (VM-1..4, SW-1..5): builds
        /// a pure `ModeTransition` from the LIVE state (current mode, page,
        /// scale, viewport, page size) and hands it to the applier, which
        /// realizes the destination fit + margins and lands the reading
        /// position with the rewind pattern. Non-standard zoom/pan is not
        /// persisted per mode (SW-5) — the transition targets are standard.
        func apply(displayModeRaw: Int) {
            guard let view else { return }
            let before = view.displayMode.rawValue
            guard
                let document = view.document,
                let from = ViewMode(displayModeRaw: before),
                let to = ViewMode(displayModeRaw: displayModeRaw),
                let page = view.currentPage
            else {
                // No live geometry yet (no document/page): fall back to a plain
                // display-mode set so the mode still changes.
                view.displayMode = PDFDisplayMode(rawValue: displayModeRaw)
                    ?? .singlePageContinuous
                log.debug(
                    .viewmode,
                    "apply displayMode \(before)→\(view.displayMode.rawValue) "
                        + "(no live geometry; plain set)"
                )
                return
            }
            let currentIndex = document.index(for: page)
            let pageSize = page.bounds(for: view.displayBox).size
            let transition = ViewModePlanner.transition(
                from: from, to: to,
                currentPageIndex: currentIndex, currentScale: view.scaleFactor,
                viewport: view.bounds.size, pageSize: pageSize)
            log.debug(
                .viewmode,
                "apply displayMode \(before)→\(displayModeRaw) page=\(currentIndex) "
                    + "vp=\(view.bounds.size) pageSize=\(pageSize) "
                    + "liveScale=\(view.scaleFactor) → transition scale=\(transition.scaleFactor) "
                    + "target=\(transition.targetPageIndex) anchor=\(transition.scrollAnchor)"
            )
            LayoutApplier.apply(transition, to: view, log: log)
        }

        /// FIT-1 — fit the current page to the viewport width within the current
        /// mode, leaving margin M left/right, WITHOUT jumping the vertical
        /// reading position (the applier preserves the clip origin.y).
        func fitWidth() {
            guard
                let view,
                let page = view.currentPage,
                let mode = ViewMode(displayModeRaw: view.displayMode.rawValue)
            else { return }
            let pageSize = page.bounds(for: view.displayBox).size
            let plan = ViewModePlanner.fitPlan(
                mode: mode, axis: .width, viewport: view.bounds.size, pageSize: pageSize)
            log.debug(
                .layout,
                "fitWidth mode=\(mode.rawValue) vp=\(view.bounds.size) "
                    + "page=\(pageSize) → scale=\(plan.scaleFactor)"
            )
            LayoutApplier.apply(plan, to: view, log: log, preserveVerticalScroll: true)
        }

        /// FIT-2 — re-fit the current page to the viewport height in place
        /// (`pageH·scale + 2M == viewportH`), centered; no page jump.
        func fitHeight() {
            guard
                let view,
                let page = view.currentPage,
                let mode = ViewMode(displayModeRaw: view.displayMode.rawValue)
            else { return }
            let pageSize = page.bounds(for: view.displayBox).size
            let plan = ViewModePlanner.fitPlan(
                mode: mode, axis: .height, viewport: view.bounds.size, pageSize: pageSize)
            log.debug(
                .layout,
                "fitHeight mode=\(mode.rawValue) vp=\(view.bounds.size) "
                    + "page=\(pageSize) → scale=\(plan.scaleFactor)"
            )
            LayoutApplier.apply(plan, to: view, log: log, preserveVerticalScroll: false)
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
