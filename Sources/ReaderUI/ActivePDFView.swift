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
        // Bare arrow keys step through this pane's Coordinator (NAV-1/NAV-2),
        // matching the status-bar arrows and palette commands.
        view.onStepForward = { [weak coordinator] in coordinator?.goToNextPage() }
        view.onStepBackward = { [weak coordinator] in coordinator?.goToPreviousPage() }

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
        // Stop any in-flight content-box preload — the view is going away.
        coordinator.cancelContentBoxPrefetch()
        // Revert any two-up / trim box overrides so the shared in-memory document
        // is restored to its original page boxes (never persisted) — otherwise a
        // theme rebuild (this view is `.id`'d on theme) would lay out a mutated
        // document (#59 bug 2).
        coordinator.revertPageBoxes()
        if coordinator.model?.primaryController === coordinator {
            coordinator.model?.primaryController = nil
        }
        if coordinator.model?.splitController === coordinator {
            coordinator.model?.splitController = nil
        }
        view.onLinkActivated = nil
        view.onLinkSplit = nil
        view.onStepForward = nil
        view.onStepBackward = nil
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
        /// In-memory page-box overrides for two-up alignment of different-size
        /// pages (SIZE-3/4). Applied on entering a two-up mode, reverted on
        /// leaving it or on teardown — never writes the file (Calibre read-only).
        private let pageBoxStore = PageBoxStore()
        /// TRIM state for this tab's live view (seeded from the tab, persisted
        /// back through the model). Drives whether `rebuildBoxState` crops each
        /// page to its content box or leaves the publisher's page.
        private var trimMargins = false
        /// Background content-box preloader (#59 bug 1): detects every page's
        /// content box OFF the main thread so trim never renders the whole
        /// document synchronously (the white-flash root cause). The visible
        /// page is detected synchronously for instant feedback; this fills in
        /// the rest and seeds the on-page cache.
        private let contentBoxService = ContentBoxService()
        private var contentBoxPrefetch: Task<Void, Never>?
        /// True once the whole document's content boxes are cached — subsequent
        /// trim toggles are then a pure `setBounds` with no render.
        private var contentBoxesReady = false
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
            self.trimMargins = model.tabs.first { $0.id == tabID }?.trimMargins ?? false
        }

        deinit {
            contentBoxPrefetch?.cancel()
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
                    // SIZE-1: single fixed applies ONE scaleFactor, but pages
                    // differ in size — re-fit the page that just became current
                    // so it stays centered with margins ≥ M (no-op in other
                    // modes).
                    LayoutApplier.refitSingleFixed(view, log: self.log)
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
            // The document's own even/odd pairing (from its /PageLayout
            // catalog entry) drives the spread anchor and the live book/RTL
            // flags (VM-5/VM-6).
            let bookLayout = ViewModePlanner.bookLayout(of: document)
            // Rebuild the in-memory box overrides for the DESTINATION mode and the
            // current trim state (SIZE-3/4 two-up enlarge, TRIM crop, or the
            // composition of both) BEFORE reading pageSize, so the transition's
            // fit is computed from the resulting box (== currentPage box).
            rebuildBoxState(mode: to, document: document, layout: bookLayout)
            let pageSize = page.bounds(for: view.displayBox).size
            let transition = ViewModePlanner.transition(
                from: from, to: to,
                currentPageIndex: currentIndex, currentScale: view.scaleFactor,
                viewport: view.bounds.size, pageSize: pageSize,
                layout: bookLayout)
            log.debug(
                .viewmode,
                "apply displayMode \(before)→\(displayModeRaw) page=\(currentIndex) "
                    + "vp=\(view.bounds.size) pageSize=\(pageSize) "
                    + "liveScale=\(view.scaleFactor) → transition scale=\(transition.scaleFactor) "
                    + "target=\(transition.targetPageIndex) anchor=\(transition.scrollAnchor)"
            )
            LayoutApplier.apply(transition, to: view, log: log)
        }

        /// TRIM-1..7 — crop every page to its printed content box, or revert.
        /// Recomputes the current mode's standard plan from the resulting
        /// (cropped/original) page sizes and re-applies it, preserving the
        /// vertical scroll in continuous modes (TRIM-2/4) and re-fitting in place
        /// for fixed modes (TRIM-1/3). Toggling never moves scroll/pan.
        ///
        /// TRIM-7: the current page is detected synchronously so trim appears at
        /// once; whole-document detection is cached and was measured at
        /// ~1.4 ms/page (0.857 s for a 593-page book, one-time). See `setTrim`'s
        /// deferred sweep note.
        func setTrim(_ on: Bool) {
            guard
                let view,
                let document = view.document,
                let mode = ViewMode(displayModeRaw: view.displayMode.rawValue),
                let page = view.currentPage
            else { return }
            trimMargins = on
            let layout = ViewModePlanner.bookLayout(of: document)
            // Capture the reading position SEMANTICALLY before cropping — the
            // crop changes every page's height, so a raw clip.y would land on a
            // different page (#59 bug 5). Continuous modes restore it after the
            // refit; fixed modes re-fit the page in place.
            let position = mode.isContinuous ? LayoutApplier.capturePagePosition(in: view) : nil
            // `rebuildBoxState` kicks off the whole-document detection off the
            // main thread (#59 bug 1); the visible page(s) are detected
            // synchronously so the toggle shows at once.
            rebuildBoxState(mode: mode, document: document, layout: layout)
            let pageSize = page.bounds(for: view.displayBox).size
            let plan = ViewModePlanner.standardPlan(
                mode: mode, viewport: view.bounds.size, pageSize: pageSize)
            log.debug(
                .trim,
                "setTrim=\(on) mode=\(mode.rawValue) pages=\(document.pageCount) "
                    + "page=\(document.index(for: page)) position=\(position.map { "\($0)" } ?? "nil") "
                    + "pageSize=\(pageSize) → scale=\(plan.scaleFactor)"
            )
            LayoutApplier.apply(plan, to: view, log: log, restorePosition: position)
        }

        /// Detects every page's content box on the background `ContentBoxService`
        /// (once per document), seeds the on-page cache, then re-applies the box
        /// state + standard plan so the WHOLE document is trimmed — cheaply (no
        /// render) and off the toggle's critical path (#59 bug 1). No-op if
        /// already prefetched or in flight.
        private func prefetchContentBoxes(document: PDFDocument) {
            guard
                !contentBoxesReady, contentBoxPrefetch == nil,
                let tab = model?.tabs.first(where: { $0.id == tabID }),
                let url = model?.url(for: tab)
            else { return }
            contentBoxPrefetch = Task { [weak self] in
                guard let service = self?.contentBoxService else { return }
                let boxes = try? await service.detectContentBoxes(at: url)
                guard let self, !Task.isCancelled, let boxes else { return }
                self.applyPrefetchedBoxes(boxes, document: document)
            }
        }

        /// Main-thread completion of the background preload: seed every page's
        /// cache (so `rebuildBoxState` becomes a pure `setBounds`), then re-apply
        /// the current mode's trim if it is still on.
        private func applyPrefetchedBoxes(_ boxes: [Int: CGRect], document: PDFDocument) {
            for i in 0..<document.pageCount {
                if let page = document.page(at: i) {
                    PageContentDetector.seedCache(boxes[i], on: page)
                }
            }
            contentBoxesReady = true
            contentBoxPrefetch = nil
            guard
                trimMargins,
                let view,
                let doc = view.document,
                let mode = ViewMode(displayModeRaw: view.displayMode.rawValue),
                let page = view.currentPage
            else { return }
            let position = mode.isContinuous ? LayoutApplier.capturePagePosition(in: view) : nil
            let layout = ViewModePlanner.bookLayout(of: doc)
            rebuildBoxState(mode: mode, document: doc, layout: layout)
            let pageSize = page.bounds(for: view.displayBox).size
            let plan = ViewModePlanner.standardPlan(
                mode: mode, viewport: view.bounds.size, pageSize: pageSize)
            log.debug(
                .trim,
                "applyPrefetchedBoxes seeded=\(boxes.count) mode=\(mode.rawValue) "
                    + "→ scale=\(plan.scaleFactor)")
            LayoutApplier.apply(plan, to: view, log: log, restorePosition: position)
        }

        /// Reverts any in-memory box overrides and re-applies the composition for
        /// `mode` + the current `trimMargins`: two-up enlarges each page to the
        /// document's uniform cell (SIZE-3/4, blank padding, content spine-ward);
        /// trim crops each page to its detected content box (TRIM); two-up + trim
        /// composes — the CROPPED content boxes feed `twoUpBoxOverrides` so the
        /// spread still abuts the gutter (TRIM-3/4/6). All overrides are in-memory
        /// only (`PageBoxStore` never writes the file — Calibre read-only).
        private func rebuildBoxState(
            mode: ViewMode, document: PDFDocument, layout: BookLayout
        ) {
            pageBoxStore.revert(document: document)
            // Ensure the whole document's content boxes are being detected in the
            // background whenever trim is on — covers toggles, mode switches, and
            // trim restored from a session (#59 bug 1).
            if trimMargins { prefetchContentBoxes(document: document) }
            let count = document.pageCount
            // Detect the VISIBLE page(s) synchronously (one render — trim shows
            // at once); every other page uses only its CACHED box, never a
            // synchronous render, so a whole-document toggle can't blank the view
            // white (#59 bug 1). The background `ContentBoxService` fills the
            // cache; until it does, off-screen pages stay uncropped, then snap in.
            let visible = trimMargins ? currentVisibleIndices(mode: mode, document: document) : []
            func detectedBox(_ i: Int) -> CGRect? {
                guard let page = document.page(at: i) else { return nil }
                if visible.contains(i) { return PageContentDetector.contentBox(of: page) }
                return PageContentDetector.cachedContentBox(of: page)?.box
            }

            if mode.isTwoUp && trimMargins && contentBoxesReady {
                // Compose crop→pad into ONE final rect per page (#59 bug 4) and
                // build the uniform cell from the TRIMMED content only (#59 bug
                // 3): untrimmed pages (absent from `detected`) keep their own box
                // rather than ballooning the cell to full-page size. Gated on the
                // whole document being detected (`contentBoxesReady`) because the
                // cell is the document-wide max of the trimmed boxes; until the
                // background preload lands we fall through to the normal two-up
                // enlarge below (#59 bug 1 — no synchronous whole-doc render).
                var detected: [Int: CGRect] = [:]
                for i in 0..<count {
                    if let box = detectedBox(i) { detected[i] = box }
                }
                let overrides = ViewModePlanner.twoUpTrimOverrides(
                    detected: detected, layout: layout, vAlign: .center)
                pageBoxStore.crop(overrides: overrides, to: document)
            } else if mode.isTwoUp {
                let contents = (0..<count).map {
                    document.page(at: $0)?.bounds(for: .cropBox) ?? .zero
                }
                let overrides = ViewModePlanner.twoUpBoxOverrides(
                    pageContents: contents, layout: layout, vAlign: .center)
                pageBoxStore.apply(overrides: overrides, to: document)
            } else if trimMargins {
                // Single call to `detectedBox` per page (was called twice — #59
                // bug 1).
                var overrides: [Int: CGRect] = [:]
                for i in 0..<count {
                    if let box = detectedBox(i) { overrides[i] = box }
                }
                pageBoxStore.crop(overrides: overrides, to: document)
            }
            // single + no-trim: reverted to originals, nothing to apply.
            log.debug(
                .trim,
                "rebuildBoxState mode=\(mode.rawValue) trim=\(trimMargins) "
                    + "pages=\(count) visible=\(visible.sorted()) active=\(pageBoxStore.isActive)"
            )
        }

        /// The page indices currently on screen: the current page, plus its
        /// spread partner in a two-up mode. Only these are detected synchronously
        /// on a trim toggle so the visible result appears immediately without a
        /// whole-document render (#59 bug 1).
        private func currentVisibleIndices(
            mode: ViewMode, document: PDFDocument
        ) -> Set<Int> {
            guard let page = view?.currentPage else { return [] }
            let current = document.index(for: page)
            var set: Set<Int> = [current]
            if mode.isTwoUp {
                let pr = ViewModePlanner.pair(
                    containing: current, layout: ViewModePlanner.bookLayout(of: document))
                for slot in [pr.left, pr.right] { if let i = slot { set.insert(i) } }
            }
            return set.filter { (0..<document.pageCount).contains($0) }
        }

        /// Reverts any two-up box overrides — called when leaving two-up and on
        /// teardown so the shared in-memory document is left in its original box
        /// state.
        func revertPageBoxes() {
            guard let document = view?.document, pageBoxStore.isActive else { return }
            pageBoxStore.revert(document: document)
        }

        /// Cancels an in-flight background content-box preload (teardown).
        func cancelContentBoxPrefetch() {
            contentBoxPrefetch?.cancel()
            contentBoxPrefetch = nil
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

        /// A "step" back/forward (arrow keys, status-bar arrows, palette). In
        /// FIXED modes we defer to PDFView's own paging (a "page" is a spread in
        /// two-up). In CONTINUOUS modes PDFKit's paging lands the page top one
        /// inset down (Fact 4) — NAV-1/NAV-2 instead land the target page/row's
        /// top at margin M (single) or, when the page fully fits, centered — so
        /// stepping matches FIXED mode. The target index is computed here (next/
        /// prev page for single; the next/prev ROW's anchor for double, honoring
        /// the book pairing), then handed to the applier's rewind-pattern scroll.
        func goToPreviousPage() {
            guard let view, view.canGoToPreviousPage else { return }
            guard
                let mode = ViewMode(displayModeRaw: view.displayMode.rawValue),
                mode.isContinuous
            else {
                view.goToPreviousPage(nil)
                return
            }
            stepContinuous(mode: mode, forward: false)
        }

        func goToNextPage() {
            guard let view, view.canGoToNextPage else { return }
            guard
                let mode = ViewMode(displayModeRaw: view.displayMode.rawValue),
                mode.isContinuous
            else {
                view.goToNextPage(nil)
                return
            }
            stepContinuous(mode: mode, forward: true)
        }

        /// Computes the continuous-mode step target and drives the applier.
        /// Single: next/prev PAGE, landing top at M (or centered if fit-height).
        /// Double: next/prev ROW anchor via the Phase-5 pairing, top at M.
        private func stepContinuous(mode: ViewMode, forward: Bool) {
            guard
                let view,
                let document = view.document,
                let page = view.currentPage
            else { return }
            let currentIndex = document.index(for: page)
            let targetIndex: Int
            let centeredIfFits: Bool
            if mode == .doubleContinuous {
                let layout = ViewModePlanner.bookLayout(of: document)
                targetIndex = forward
                    ? ViewModePlanner.nextRowLeftIndex(currentIndex: currentIndex, layout: layout)
                    : ViewModePlanner.previousRowLeftIndex(currentIndex: currentIndex, layout: layout)
                centeredIfFits = false          // NAV-2 rows always land top at M
            } else {
                targetIndex = forward ? currentIndex + 1 : currentIndex - 1
                centeredIfFits = true           // NAV-1 fit-height ⇒ equal margins
            }
            let clamped = min(max(0, targetIndex), max(0, document.pageCount - 1))
            log.debug(
                .nav,
                "step \(forward ? "next" : "prev") mode=\(mode.rawValue) "
                    + "from=\(currentIndex) → target=\(clamped) centeredIfFits=\(centeredIfFits)"
            )
            LayoutApplier.stepContinuous(
                toPageIndex: clamped, centeredIfFits: centeredIfFits, in: view, log: log)
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
