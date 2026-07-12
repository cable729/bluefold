#if os(macOS)
import AppKit
import ReaderCore

/// Identity of one tab strip on screen: each pane of a (possibly split)
/// reader window carries its own bar.
struct TabStripID: Hashable {
    let windowID: UUID
    let pane: ReaderPane
}

/// What the strip needs to know about one tab to draw it.
struct TabDisplayItem: Equatable {
    let id: UUID
    /// Book title — drawn once per lozenge (a run of same-book tabs).
    let title: String
    /// The tab's cell text: outline breadcrumb of its position (may be a
    /// plain page label for outline-less documents).
    let breadcrumb: String
    let isActive: Bool
    /// Adjacent tabs with the same key share one lozenge: the book swatch
    /// and title drawn once, a chapter cell per tab.
    let groupKey: String
    /// The book's stable tint (cover palette) — colors the swatch and the
    /// lozenge's translucent fill.
    let tint: NSColor
}

/// Everything the strip can ask its window model to do. Kept as closures so
/// the NSView never retains the model and stays trivially previewable.
@MainActor
struct TabStripActions {
    var select: (UUID) -> Void
    var close: (UUID) -> Void
    var closeMany: ([UUID]) -> Void = { _ in }
    var duplicate: (UUID) -> Void
    var closeOthers: (UUID) -> Void
    var openInSplit: (UUID, SplitSide) -> Void = { _, _ in }
    var closeSplit: () -> Void = {}
    /// Sends a split-strip tab back to the primary strip (and vice versa).
    var moveToOtherPane: (UUID) -> Void = { _ in }
    var reorder: (UUID, Int) -> Void
    /// Cross-strip move: (tabID, targetStrip, insertionIndex) — the target
    /// may be another window OR this window's other pane.
    var moveToStrip: (UUID, TabStripID, Int) -> Void
    /// Tab dropped on empty desktop at a screen point.
    var detachToNewWindow: (UUID, CGPoint) -> Void
    /// Tab dropped on a reader window's content-area half:
    /// (tabID, targetWindowID, side) — opens as that window's split.
    var dropIntoSplit: (UUID, UUID, SplitSide) -> Void = { _, _, _ in }
}

/// AppKit-backed tab strip in the Cloth & Paper design: same-book tabs share
/// a tinted LOZENGE (book swatch + title once, a chapter cell per tab; the
/// active cell is a quiet full-cell fill in the divider's ink). SwiftUI's
/// .draggable/.onTapGesture combination proved unreliable for tab dragging
/// (gesture conflicts, no way to detect desktop drops), so the strip tracks
/// the mouse itself:
///   - horizontal drag inside the strip band → live reorder preview, commit
///     on mouse-up
///   - drag beyond ±`Self.tearOffDistance` vertically → tear-off: a ghost
///     panel follows the pointer; dropping over another strip moves the tab
///     there (other windows AND this window's other pane), dropping anywhere
///     else opens a new window at the point.
/// Cross-strip hit-testing goes through `TabStripRegistry`.
///
/// Cells take their natural text width; when the total overflows the strip,
/// cells first shrink toward a floor and then the strip SCROLLS horizontally
/// (Firefox/Chrome behavior) — it lives inside `TabStripScrollView`.
/// While a drag is in flight everything renders as uniform singletons so
/// slot math stays trivial.
@MainActor
final class TabStripNSView: NSView {
    static let stripHeight: CGFloat = 38
    static let lozengeInsetY: CGFloat = 5
    static let lozengeGap: CGFloat = 6
    static let edgePadding: CGFloat = 8
    static let cornerRadius: CGFloat = 8
    static let minCellWidth: CGFloat = 44
    static let maxCellTextWidth: CGFloat = 220
    static let maxLabelTextWidth: CGFloat = 240
    /// Overflow shrink floors: cells/labels never compress past these —
    /// past them the strip SCROLLS instead of crushing text into
    /// unreadability (owner feedback: "make it so I can actually read
    /// the name of the book and chapters").
    static let readableCellWidth: CGFloat = 100
    static let readableLabelWidth: CGFloat = 110
    static let dragCellWidth: CGFloat = 140
    static let tearOffDistance: CGFloat = 44

    let stripID: TabStripID
    var windowID: UUID { stripID.windowID }
    var actions: TabStripActions

    private(set) var items: [TabDisplayItem] = []
    private(set) var palette: DesignPalette = .light
    /// Whether the window is split — decides the context menu's verbs.
    private var isWindowSplit = false
    private var itemViews: [TabItemNSView] = []
    private var lozengeViews: [TabLozengeView] = []
    private var drag: DragState?
    /// Set while THIS strip's layout runs so frame-change observation in
    /// the scroll container can tell relayout from external resizes.
    private(set) var contentWidth: CGFloat = 0

    /// Multi-selection for bulk actions (⌘-click toggles, ⇧-click extends
    /// from the active tab). Purely view state; cleared by plain clicks and
    /// content changes.
    private(set) var multiSelection: Set<UUID> = []

    /// Highlight shown while a foreign tab drag hovers over this strip.
    private var isDropTarget = false {
        didSet { needsDisplay = (isDropTarget != oldValue) || needsDisplay }
    }

    init(stripID: TabStripID, actions: TabStripActions) {
        self.stripID = stripID
        self.actions = actions
        super.init(frame: .zero)
        wantsLayer = true
        // NSViews don't clip subviews by default; without this a mislaid
        // frame (or an in-flight animation) draws over neighboring chrome.
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(
            stripID.pane == .split ? "tab-strip-split" : "tab-strip"
        )
        setAccessibilityEnabled(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            TabStripRegistry.shared.register(self, for: stripID)
        } else {
            TabStripRegistry.shared.unregister(stripID: stripID)
            // The strip left its window mid-drag (window closed, hierarchy
            // rebuilt): a live ghost would float forever.
            cancelDrag(reason: "left window")
        }
    }

    // MARK: - Content

    func apply(items: [TabDisplayItem], palette: DesignPalette, isWindowSplit: Bool) {
        let paletteChanged = palette.stripBackground != self.palette.stripBackground
        self.palette = palette
        self.isWindowSplit = isWindowSplit
        guard items != self.items || paletteChanged else { return }
        let activeChanged = items.first(where: \.isActive)?.id
            != self.items.first(where: \.isActive)?.id
        self.items = items

        // The dragged tab vanished from the model (closed from elsewhere,
        // moved by code): the drag has nothing to commit — end it now,
        // before its item view is orphaned and stops receiving events.
        if let drag, !items.contains(where: { $0.id == drag.tabID }) {
            cancelDrag(reason: "dragged tab removed")
        }

        // Reuse views by tab ID so hover state survives reorders.
        var existing: [UUID: TabItemNSView] = [:]
        for view in itemViews { existing[view.tabID] = view }
        itemViews = items.map { item in
            let view = existing.removeValue(forKey: item.id)
                ?? TabItemNSView(tabID: item.id, owner: self)
            view.apply(item, palette: palette)
            if view.superview !== self { addSubview(view) }
            return view
        }
        for (_, orphan) in existing { orphan.removeFromSuperview() }

        // Selection can only reference live tabs.
        let live = Set(items.map(\.id))
        multiSelection.formIntersection(live)
        applyMultiSelectionChrome()
        needsLayout = true
        if activeChanged {
            // After layout, bring the newly active cell into view
            // (selection from the palette/⌘1–9 may target a scrolled-out tab).
            DispatchQueue.main.async { [weak self] in self?.scrollActiveCellToVisible() }
        }
    }

    private func scrollActiveCellToVisible() {
        guard drag == nil,
              let active = itemViews.first(where: { view in
                  items.first { $0.id == view.tabID }?.isActive == true
              })
        else { return }
        scrollToVisible(active.frame.insetBy(dx: -20, dy: 0))
    }

    // MARK: - Multi-selection

    private func applyMultiSelectionChrome() {
        for view in itemViews {
            view.setMultiSelected(multiSelection.contains(view.tabID))
        }
    }

    private func clearMultiSelection() {
        guard !multiSelection.isEmpty else { return }
        multiSelection.removeAll()
        applyMultiSelectionChrome()
    }

    /// ⌘-click membership toggle.
    private func toggleMultiSelection(_ tabID: UUID) {
        if multiSelection.isEmpty, let active = items.first(where: \.isActive) {
            // Seed with the active tab so ⌘-clicking one other tab yields a
            // meaningful two-tab selection, Finder-style.
            multiSelection.insert(active.id)
        }
        if !multiSelection.insert(tabID).inserted {
            multiSelection.remove(tabID)
        }
        applyMultiSelectionChrome()
    }

    /// ⇧-click range from the active tab.
    private func extendMultiSelection(to tabID: UUID) {
        guard
            let anchor = items.firstIndex(where: \.isActive),
            let target = items.firstIndex(where: { $0.id == tabID })
        else { return }
        let range = min(anchor, target)...max(anchor, target)
        multiSelection = Set(items[range].map(\.id))
        applyMultiSelectionChrome()
    }

    // MARK: - Layout (variable-width lozenges; scrolls on overflow)

    override func layout() {
        super.layout()
        layoutItems(animated: false)
    }

    /// Width available before the strip must scroll.
    private var availableWidth: CGFloat {
        enclosingScrollView?.contentView.bounds.width ?? bounds.width
    }

    private struct RunLayout {
        var range: Range<Int>
        var labelWidth: CGFloat // 0 while dragging (no book labels)
        var cellWidths: [CGFloat]
        var width: CGFloat { labelWidth + cellWidths.reduce(0, +) }
    }

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// Cells are measured at SEMIBOLD: the active cell renders semibold,
    /// and measuring regular truncated it (semibold is wider).
    private static let cellFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    private static func textWidth(_ string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// Ranges of adjacent items sharing a groupKey (length ≥ 1: every tab
    /// lives in a lozenge, singletons included).
    private func runRanges(of items: [TabDisplayItem]) -> [Range<Int>] {
        guard !items.isEmpty else { return [] }
        var runs: [Range<Int>] = []
        var start = 0
        for index in 1...items.count {
            if index == items.count || items[index].groupKey != items[start].groupKey {
                runs.append(start..<index)
                start = index
            }
        }
        return runs
    }

    /// Natural (unshrunk) layout of the given visual order, then a shrink
    /// pass toward `minCellWidth` when the total overflows; beyond that the
    /// strip scrolls.
    private func computeRuns(for ordered: [TabDisplayItem], dragging: Bool) -> [RunLayout] {
        if dragging {
            // Uniform singleton cells (title text) keep slot math trivial.
            let count = max(ordered.count, 1)
            let fit = (availableWidth
                - 2 * Self.edgePadding
                - CGFloat(count - 1) * Self.lozengeGap) / CGFloat(count)
            let width = max(Self.minCellWidth, min(Self.dragCellWidth, fit))
            return ordered.indices.map {
                RunLayout(range: $0..<($0 + 1), labelWidth: 0, cellWidths: [width])
            }
        }
        var runs: [RunLayout] = runRanges(of: ordered).map { range in
            let labelText = Self.textWidth(ordered[range.lowerBound].title, font: Self.labelFont)
            // swatch 9 + gaps + title (+ NSTextField's own padding) + padding
            let label = 7 + 9 + 6 + min(labelText + 6, Self.maxLabelTextWidth) + 4
            let cells = range.map { index -> CGFloat in
                let item = ordered[index]
                let text = min(
                    Self.textWidth(item.breadcrumb, font: Self.cellFont) + 4,
                    Self.maxCellTextWidth
                )
                // Mirror the cell's constraint chain exactly (leading 9 +
                // text + 3 + close 12 + trailing 7); the ✕ slot is always
                // reserved so hover/active never reflows the text.
                return max(Self.minCellWidth, 9 + text + 3 + 12 + 7)
            }
            return RunLayout(range: range, labelWidth: label, cellWidths: cells)
        }

        let chrome = 2 * Self.edgePadding + CGFloat(max(runs.count - 1, 0)) * Self.lozengeGap
        let natural = runs.reduce(chrome) { $0 + $1.width }
        let available = availableWidth
        if natural > available {
            // Shrink labels and cells together, proportionally to how far
            // each sits above its READABLE floor; whatever still overflows
            // scrolls. (Never crush to the bare minimum — round-20 owner
            // feedback: names and chapters must stay legible.)
            func cellFloor(_ width: CGFloat) -> CGFloat { min(width, Self.readableCellWidth) }
            func labelFloor(_ width: CGFloat) -> CGFloat { min(width, Self.readableLabelWidth) }
            let slack = runs.reduce(0) { total, run in
                total + (run.labelWidth - labelFloor(run.labelWidth))
                    + run.cellWidths.reduce(0) { $0 + ($1 - cellFloor($1)) }
            }
            if slack > 0 {
                let factor = min(1, (natural - available) / slack)
                for runIndex in runs.indices {
                    let label = runs[runIndex].labelWidth
                    runs[runIndex].labelWidth = label - (label - labelFloor(label)) * factor
                    runs[runIndex].cellWidths = runs[runIndex].cellWidths.map {
                        $0 - ($0 - cellFloor($0)) * factor
                    }
                }
            }
        }
        return runs
    }

    /// Shrink-then-scroll layout. During a drag the dragged tab tracks the
    /// pointer and others make room.
    private func layoutItems(animated: Bool) {
        guard !itemViews.isEmpty else {
            clearLozenges()
            contentWidth = 0
            resizeToContent(width: availableWidth)
            return
        }
        let dragging = drag?.didMove == true
        let orderedViews = orderedViewsForLayout()
        let orderedItems: [TabDisplayItem] = orderedViews.compactMap { view in
            items.first { $0.id == view.tabID }
        }
        let runs = computeRuns(for: orderedItems, dragging: dragging)

        let lozengeHeight = Self.stripHeight - 2 * Self.lozengeInsetY
        var lozengeFrames: [NSRect] = []
        var labelWidths: [CGFloat] = []
        var x = Self.edgePadding
        for run in runs {
            let frame = NSRect(
                x: x, y: Self.lozengeInsetY,
                width: run.width, height: lozengeHeight
            )
            lozengeFrames.append(frame)
            labelWidths.append(run.labelWidth)

            var cellX = x + run.labelWidth
            for (offset, index) in run.range.enumerated() {
                let view = orderedViews[index]
                let width = run.cellWidths[offset]
                let target = NSRect(
                    x: cellX, y: Self.lozengeInsetY,
                    width: width, height: lozengeHeight
                )
                let isLast = offset == run.range.count - 1
                let isFirst = offset == 0 && run.labelWidth == 0
                view.setCellShape(
                    roundsLeft: isFirst, roundsRight: isLast,
                    showsLeadingDivider: !(offset == 0)
                )
                view.setDragAppearance(dragging)
                if view === drag?.itemView, dragging, drag?.isTornOff == false {
                    // The dragged tab follows the pointer horizontally.
                    var f = target
                    f.origin.x = drag!.currentTabOriginX(
                        tabWidth: width, stripWidth: max(contentWidth, availableWidth)
                    )
                    view.frame = f
                } else {
                    setFrame(target, of: view, animated: animated)
                }
                cellX += width
            }
            x = lozengeFrames.last!.maxX + Self.lozengeGap
        }

        layoutLozenges(
            frames: lozengeFrames, labelWidths: labelWidths,
            runs: runs, ordered: orderedItems, animated: animated
        )

        contentWidth = (lozengeFrames.last?.maxX ?? 0) + Self.edgePadding
        resizeToContent(width: max(contentWidth, availableWidth))
    }

    /// Grows the strip to its content (the scroll view shows the rest).
    private func resizeToContent(width: CGFloat) {
        let height = enclosingScrollView?.contentView.bounds.height ?? Self.stripHeight
        let size = NSSize(width: width, height: height)
        if frame.size != size {
            setFrameSize(size)
        }
    }

    private func layoutLozenges(
        frames: [NSRect], labelWidths: [CGFloat],
        runs: [RunLayout], ordered: [TabDisplayItem], animated: Bool
    ) {
        // Reuse lozenge views positionally; runs are few.
        while lozengeViews.count > frames.count {
            lozengeViews.removeLast().removeFromSuperview()
        }
        while lozengeViews.count < frames.count {
            let lozenge = TabLozengeView(owner: self)
            lozengeViews.append(lozenge)
            addSubview(lozenge, positioned: .below, relativeTo: itemViews.first)
        }
        for (index, lozenge) in lozengeViews.enumerated() {
            let run = runs[index]
            let first = ordered[run.range.lowerBound]
            let runIsActive = run.range.contains { ordered[$0].isActive }
            lozenge.apply(
                title: labelWidths[index] > 0 ? first.title : "",
                labelWidth: labelWidths[index],
                tint: first.tint,
                isActive: runIsActive,
                firstTabID: first.id,
                palette: palette
            )
            setFrame(frames[index], of: lozenge, animated: animated)
        }
    }

    /// Animated frame changes, EXCEPT a view's very first placement: a view
    /// added this cycle still sits at .zero, and animating from there makes
    /// its text glide in from the strip's corner (round-4 "looks awful").
    private func setFrame(_ frame: NSRect, of view: NSView, animated: Bool) {
        if animated, view.frame != .zero {
            view.animator().frame = frame
        } else {
            view.frame = frame
        }
    }

    private func clearLozenges() {
        for lozenge in lozengeViews { lozenge.removeFromSuperview() }
        lozengeViews.removeAll()
    }

    /// Item views in visual order: model order, adjusted by the in-flight
    /// drag preview (dragged tab occupies its provisional slot).
    private func orderedViewsForLayout() -> [TabItemNSView] {
        guard let drag else { return itemViews }
        if drag.isTornOff {
            return itemViews.filter { $0 !== drag.itemView }
        }
        var views = itemViews.filter { $0 !== drag.itemView }
        let slot = max(0, min(drag.previewIndex, views.count))
        views.insert(drag.itemView, at: slot)
        return views
    }

    /// Provisional slot for the pointer while reordering. Drag mode lays
    /// cells out uniformly (same formula as `computeRuns`), so the slot is
    /// pure arithmetic — no dependence on in-flight animations.
    private func slotIndex(forX x: CGFloat) -> Int {
        let count = max(itemViews.count, 1)
        let fit = (availableWidth
            - 2 * Self.edgePadding
            - CGFloat(count - 1) * Self.lozengeGap) / CGFloat(count)
        let width = max(Self.minCellWidth, min(Self.dragCellWidth, fit))
        let slot = Int((x - Self.edgePadding) / (width + Self.lozengeGap))
        return max(0, min(slot, itemViews.count - 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isDropTarget {
            palette.accent.withAlphaComponent(0.15).setFill()
            bounds.fill()
        }
    }

    // MARK: - Drag tracking

    private struct DragState {
        let itemView: TabItemNSView
        let tabID: UUID
        let startInStrip: CGPoint
        let startScreen: CGPoint
        let grabOffsetX: CGFloat // pointer x within the tab at mouse-down
        var previewIndex: Int
        var isTornOff = false
        var didMove = false
        var ghost: TabGhostPanel?
        var currentInStrip: CGPoint

        func currentTabOriginX(tabWidth: CGFloat, stripWidth: CGFloat) -> CGFloat {
            let raw = currentInStrip.x - grabOffsetX
            return max(0, min(raw, stripWidth - tabWidth))
        }
    }

    /// Temporary drag diagnostics (BLUEFOLD_SESSION_DIR/dragdebug.log);
    /// active only when the session-dir override is present, i.e. tests.
    static func dragLog(_ message: String) {
        guard let dir = ProcessInfo.processInfo.environment["BLUEFOLD_SESSION_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("dragdebug.log")
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Called by TabItemNSView on mouse-down; selection happens immediately
    /// (browser behavior), dragging may follow.
    func beginPress(on item: TabItemNSView, with event: NSEvent) {
        Self.dragLog("beginPress tab=\(item.tabID.uuidString.prefix(8)) loc=\(event.locationInWindow)")
        // Modifier clicks build a multi-selection instead of activating.
        if event.modifierFlags.contains(.command) {
            toggleMultiSelection(item.tabID)
            return
        }
        if event.modifierFlags.contains(.shift) {
            extendMultiSelection(to: item.tabID)
            return
        }
        clearMultiSelection()
        actions.select(item.tabID)
        let inStrip = convert(event.locationInWindow, from: nil)
        drag = DragState(
            itemView: item,
            tabID: item.tabID,
            startInStrip: inStrip,
            startScreen: screenPoint(for: event),
            grabOffsetX: inStrip.x - item.frame.minX,
            previewIndex: itemViews.firstIndex(of: item) ?? 0,
            currentInStrip: inStrip
        )
        installDragMonitors()
    }

    // MARK: - Drag failsafe monitors
    //
    // The item view owns the mouse-tracking session, but its mouseUp has been
    // observed to go missing (round-4/5: pointer released over another app →
    // ghost panel stuck floating, tab invisible, only a relaunch recovered).
    // While a drag is live, two NSEvent monitors guarantee the drag finishes:
    // a local one (mouseUp delivered anywhere in this app) and a global one
    // (mouseUp delivered to another app).

    private var dragMonitors: [Any] = []

    private func installDragMonitors() {
        removeDragMonitors()
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp],
            handler: { [weak self] event in
                if let self, self.drag != nil {
                    Self.dragLog("failsafe: local-monitor mouseUp")
                    self.endPress(with: event)
                }
                return event
            }
        )
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp],
            handler: { [weak self] _ in
                guard let self, self.drag != nil else { return }
                Self.dragLog("failsafe: global-monitor mouseUp")
                self.finishDrag(atScreen: NSEvent.mouseLocation)
            }
        )
        dragMonitors = [local, global].compactMap { $0 }
    }

    private func removeDragMonitors() {
        for monitor in dragMonitors {
            NSEvent.removeMonitor(monitor)
        }
        dragMonitors.removeAll()
    }

    /// Abandons a drag without committing anything (dragged tab vanished,
    /// strip left its window): the ghost closes, the tab reappears.
    private func cancelDrag(reason: String) {
        guard let drag else { return }
        Self.dragLog("cancelDrag reason=\(reason)")
        drag.ghost?.close()
        drag.itemView.alphaValue = 1
        self.drag = nil
        removeDragMonitors()
        TabStripRegistry.shared.updateDropTarget(at: nil, excluding: nil)
        SplitDropZoneRegistry.shared.setTarget(nil)
        needsLayout = true
    }

    func continuePress(with event: NSEvent) {
        guard var drag else { return }
        Self.dragLog("continuePress loc=\(event.locationInWindow) tornOff=\(drag.isTornOff)")
        let inStrip = convert(event.locationInWindow, from: nil)
        drag.currentInStrip = inStrip
        let dx = inStrip.x - drag.startInStrip.x
        let dy = inStrip.y - drag.startInStrip.y
        if !drag.didMove, abs(dx) < 4, abs(dy) < 4 {
            self.drag = drag
            return // below the drag threshold: still a click
        }
        drag.didMove = true

        let inBand = abs(dy) < Self.tearOffDistance
            && inStrip.x > -Self.tearOffDistance
            && inStrip.x < max(contentWidth, availableWidth) + Self.tearOffDistance
        if inBand {
            if drag.isTornOff { // re-entered: dissolve the ghost
                drag.ghost?.close()
                drag.ghost = nil
                drag.isTornOff = false
                drag.itemView.alphaValue = 1
            }
            // Provisional slot from the pointer.
            drag.previewIndex = slotIndex(forX: inStrip.x)
            self.drag = drag
            SplitDropZoneRegistry.shared.setTarget(nil) // back in the band
            layoutItems(animated: true)
        } else {
            if !drag.isTornOff {
                drag.isTornOff = true
                drag.ghost = TabGhostPanel(snapshotting: drag.itemView)
                // Invisible, NOT hidden: the view owns the mouse-tracking
                // session, and a hidden view can lose its mouseUp.
                drag.itemView.alphaValue = 0
                layoutItems(animated: true) // remaining tabs close the gap
            }
            let screen = screenPoint(for: event)
            drag.ghost?.move(to: screen)
            self.drag = drag
            // Light up whichever strip would accept the drop; when none is
            // under the pointer, light up a content-area half instead
            // (drag-to-split). Strips win: their grace band overlaps the top
            // of the content area, and a strip drop is the more deliberate
            // gesture there.
            TabStripRegistry.shared.updateDropTarget(
                at: screen, excluding: drag.isTornOff ? nil : stripID
            )
            SplitDropZoneRegistry.shared.setTarget(splitDropZone(atScreen: screen))
        }
    }

    /// The drag-to-split zone a drop at `screen` would hit, or nil when a
    /// strip claims the point or the target couldn't actually split. Shared
    /// by the hover highlight and finishDrag so they can never disagree.
    private func splitDropZone(atScreen screen: CGPoint) -> SplitDropZone? {
        guard
            TabStripRegistry.shared.strip(at: screen) == nil,
            let zone = SplitDropZoneRegistry.shared.zone(at: screen)
        else { return nil }
        // A same-window split needs another tab left for the primary pane;
        // items still contains the torn-off tab, so ≥ 2 means one remains.
        if zone.windowID == windowID, items.count < 2 { return nil }
        return zone
    }

    func endPress(with event: NSEvent) {
        Self.dragLog("endPress loc=\(event.locationInWindow) drag=\(drag.map { "didMove=\($0.didMove) tornOff=\($0.isTornOff)" } ?? "nil")")
        finishDrag(atScreen: screenPoint(for: event))
    }

    /// Commits the drag: reorder in-band, move/detach when torn off. Every
    /// way a drag can end — the item's own mouseUp or either failsafe
    /// monitor — funnels here; the first caller wins, the rest no-op.
    private func finishDrag(atScreen screen: CGPoint) {
        guard let drag else { return }
        removeDragMonitors()
        defer {
            self.drag = nil
            TabStripRegistry.shared.updateDropTarget(at: nil, excluding: nil)
            SplitDropZoneRegistry.shared.setTarget(nil)
            layoutItems(animated: true)
        }
        drag.ghost?.close()
        drag.itemView.alphaValue = 1

        guard drag.didMove else { return } // plain click; select already ran

        if drag.isTornOff {
            if let (targetID, targetStrip) = TabStripRegistry.shared.strip(at: screen) {
                if targetID == stripID {
                    return // dropped back on our own strip: no-op
                }
                let index = targetStrip.insertionIndex(forScreenPoint: screen)
                actions.moveToStrip(drag.tabID, targetID, index)
            } else if let zone = splitDropZone(atScreen: screen) {
                // Dropped on a reader window's content-area half: open as
                // that window's split on that side (cross-window drops move
                // the tab first, exactly like strip drops).
                actions.dropIntoSplit(drag.tabID, zone.windowID, zone.side)
            } else {
                actions.detachToNewWindow(drag.tabID, screen)
            }
        } else {
            actions.reorder(drag.tabID, drag.previewIndex)
        }
    }

    /// Where a foreign tab dropped at `screenPoint` would be inserted.
    func insertionIndex(forScreenPoint point: CGPoint) -> Int {
        guard let window else { return items.count }
        let inStrip = convert(window.convertPoint(fromScreen: point), from: nil)
        for (index, view) in itemViews.enumerated() where inStrip.x < view.frame.midX {
            return index
        }
        return items.count
    }

    func setDropTargetHighlight(_ on: Bool) {
        isDropTarget = on
        needsDisplay = true
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        guard let window = event.window ?? self.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    // MARK: - Context menu (per item; built here to keep actions in one place)

    func menu(for item: TabItemNSView) -> NSMenu {
        menu(forTabID: item.tabID)
    }

    /// Context menu for one tab — item views AND lozenge labels route here
    /// (round 14: a label-covered tab must keep its menu reachable).
    func menu(forTabID tabID: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Bulk action when the right-clicked tab is part of a multi-selection.
        if multiSelection.count > 1, multiSelection.contains(tabID) {
            let ids = items.map(\.id).filter { multiSelection.contains($0) }
            menu.addItem(
                withTitle: "Close \(ids.count) Tabs", action: nil, keyEquivalent: ""
            ).setHandler { [weak self] in self?.actions.closeMany(ids) }
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Duplicate Tab", action: nil, keyEquivalent: "")
            .setHandler { [weak self] in self?.actions.duplicate(tabID) }
        if isWindowSplit {
            menu.addItem(
                withTitle: stripID.pane == .split
                    ? "Move to Primary Pane" : "Move to Split Pane",
                action: nil, keyEquivalent: ""
            ).setHandler { [weak self] in self?.actions.moveToOtherPane(tabID) }
            menu.addItem(withTitle: "Close Split View", action: nil, keyEquivalent: "")
                .setHandler { [weak self] in self?.actions.closeSplit() }
        } else {
            // Splitting a tab moves it into the (new) split pane's strip,
            // side included.
            let splitRight = menu.addItem(
                withTitle: "Split Right", action: nil, keyEquivalent: ""
            )
            splitRight.setHandler { [weak self] in
                self?.actions.openInSplit(tabID, .trailing)
            }
            splitRight.isEnabled = items.count > 1
            let splitLeft = menu.addItem(
                withTitle: "Split Left", action: nil, keyEquivalent: ""
            )
            splitLeft.setHandler { [weak self] in
                self?.actions.openInSplit(tabID, .leading)
            }
            splitLeft.isEnabled = items.count > 1
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab", action: nil, keyEquivalent: "")
            .setHandler { [weak self] in self?.actions.close(tabID) }
        let closeOthers = menu.addItem(
            withTitle: "Close Other Tabs", action: nil, keyEquivalent: ""
        )
        closeOthers.setHandler { [weak self] in self?.actions.closeOthers(tabID) }
        closeOthers.isEnabled = items.count > 1
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to New Window", action: nil, keyEquivalent: "")
            .setHandler { [weak self] in
                guard let self else { return }
                let below = self.window?.frame.center ?? .zero
                self.actions.detachToNewWindow(tabID, below)
            }
        return menu
    }
}

/// One chapter CELL in a lozenge: breadcrumb text + close button. The active
/// cell fills with the palette's translucent ink; hover shows a whisper of
/// it. Pure display + event forwarding; all decisions live in the owning
/// strip. While a drag is in flight the cell shows the TAB TITLE instead
/// (lozenges dissolve to uniform singletons).
@MainActor
final class TabItemNSView: NSView {
    let tabID: UUID
    private unowned let owner: TabStripNSView

    private let textField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let leadingDivider = NSView()
    private var item: TabDisplayItem?
    private var palette: DesignPalette = .light
    private var isDragAppearance = false
    private var roundsLeft = false
    private var roundsRight = false
    private var isMultiSelected = false
    private var isHovered = false { didSet { refreshChrome() } }
    private var trackingArea: NSTrackingArea?

    init(tabID: UUID, owner: TabStripNSView) {
        self.tabID = tabID
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TabStripNSView.cornerRadius
        layer?.maskedCorners = []

        textField.font = NSFont.systemFont(ofSize: 11.5)
        // Head truncation keeps the deepest (most useful) section visible.
        textField.lineBreakMode = .byTruncatingHead
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setAccessibilityIdentifier("tab-breadcrumb")

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Close Tab"
        )
        closeButton.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setAccessibilityIdentifier("tab-close")

        leadingDivider.wantsLayer = true
        leadingDivider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textField)
        addSubview(closeButton)
        addSubview(leadingDivider)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -3),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            // ✕ sits on the RIGHT (round 15) — matching every browser.
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            leadingDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingDivider.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingDivider.widthAnchor.constraint(equalToConstant: 1),
            leadingDivider.heightAnchor.constraint(equalToConstant: 15),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ item: TabDisplayItem, palette: DesignPalette) {
        self.item = item
        self.palette = palette
        setAccessibilityIdentifier("tab-\(item.title)")
        setAccessibilityTitle(item.title)
        refreshChrome()
    }

    /// Outer-edge rounding follows the cell's slot in its lozenge.
    func setCellShape(roundsLeft: Bool, roundsRight: Bool, showsLeadingDivider: Bool) {
        self.roundsLeft = roundsLeft
        self.roundsRight = roundsRight
        leadingDivider.isHidden = !showsLeadingDivider
        refreshChrome()
    }

    /// While dragging, cells dissolve to title-carrying singletons.
    func setDragAppearance(_ dragging: Bool) {
        guard dragging != isDragAppearance else { return }
        isDragAppearance = dragging
        refreshChrome()
    }

    func setMultiSelected(_ selected: Bool) {
        guard selected != isMultiSelected else { return }
        isMultiSelected = selected
        refreshChrome()
    }

    private func refreshChrome() {
        guard let item else { return }
        let active = item.isActive
        textField.stringValue = isDragAppearance ? item.title : item.breadcrumb
        textField.font = NSFont.systemFont(
            ofSize: 11.5, weight: active ? .semibold : .regular
        )
        textField.textColor = active
            ? palette.ink
            : palette.ink.withAlphaComponent(0.62)
        closeButton.contentTintColor = palette.ink.withAlphaComponent(0.55)
        closeButton.isHidden = !(active || isHovered)
        leadingDivider.layer?.backgroundColor = palette.lozengeDivider.cgColor

        // AppKit's layer corner mask uses AppKit (flipped=false) geometry:
        // MinY = bottom. Round only the outer edges the lozenge exposes.
        var corners: CACornerMask = []
        if roundsLeft { corners.insert([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }
        if roundsRight { corners.insert([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }
        layer?.maskedCorners = corners

        layer?.backgroundColor =
            if isMultiSelected {
                palette.accent.withAlphaComponent(0.28).cgColor
            } else if active {
                palette.activeCellFill.cgColor
            } else if isHovered {
                palette.ink.withAlphaComponent(0.05).cgColor
            } else {
                NSColor.clear.cgColor
            }
    }

    @objc private func closeTapped() {
        owner.actions.close(tabID)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Tabs handle their own drags; never let a press move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Selecting a tab in a background window should take one click,
    /// browser-style.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        owner.beginPress(on: self, with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        owner.continuePress(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        owner.endPress(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner.menu(for: self)
    }
}

/// The tinted rounded container of one same-book run: translucent book-tint
/// fill, the cover swatch, and the book title. Click selects the run's
/// first tab; right-click gets that tab's menu.
@MainActor
final class TabLozengeView: NSView {
    private unowned let owner: TabStripNSView
    private let swatch = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private var firstTabID: UUID?
    private var labelWidth: CGFloat = 0

    init(owner: TabStripNSView) {
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TabStripNSView.cornerRadius

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 2

        titleField.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail

        addSubview(swatch)
        addSubview(titleField)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("tab-group-header")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(
        title: String, labelWidth: CGFloat, tint: NSColor,
        isActive: Bool, firstTabID: UUID?, palette: DesignPalette
    ) {
        self.firstTabID = firstTabID
        self.labelWidth = labelWidth
        titleField.stringValue = title
        titleField.textColor = palette.ink.withAlphaComponent(0.9)
        titleField.setAccessibilityIdentifier("tab-title")
        swatch.layer?.backgroundColor = tint.cgColor
        // The book tint carries the lozenge; the active book's lozenge sits
        // a notch stronger, mockup-style.
        layer?.backgroundColor = tint
            .withAlphaComponent(isActive ? 0.30 : 0.18).cgColor
        setAccessibilityTitle(title)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        swatch.frame = NSRect(x: 7, y: (bounds.height - 11) / 2, width: 9, height: 11)
        let titleX = swatch.frame.maxX + 6
        titleField.frame = NSRect(
            x: titleX,
            y: (bounds.height - titleField.intrinsicContentSize.height) / 2,
            width: max(labelWidth - titleX - 4, 0),
            height: titleField.intrinsicContentSize.height
        )
        swatch.isHidden = labelWidth <= 0
        titleField.isHidden = labelWidth <= 0
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let firstTabID {
            owner.actions.select(firstTabID)
        }
    }

    /// The label is the group's visible handle: right-click must work here
    /// too (round 14 — a covered tab had no reachable menu).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let firstTabID else { return nil }
        return owner.menu(forTabID: firstTabID)
    }
}

/// Horizontal scroller around the strip (Firefox/Chrome overflow behavior).
/// A vertical wheel scrolls horizontally — the strip has no vertical axis.
@MainActor
final class TabStripScrollView: NSScrollView {
    init(strip: TabStripNSView) {
        super.init(frame: .zero)
        documentView = strip
        hasVerticalScroller = false
        hasHorizontalScroller = true
        horizontalScroller?.controlSize = .mini
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        verticalScrollElasticity = .none
        contentView.postsBoundsChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: TabStripNSView.stripHeight)
    }

    override func layout() {
        super.layout()
        // Width changes re-run the shrink-then-scroll pass.
        (documentView as? TabStripNSView)?.needsLayout = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let strip = documentView as? TabStripNSView,
              strip.frame.width > contentView.bounds.width,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        else {
            super.scrollWheel(with: event)
            return
        }
        var origin = contentView.bounds.origin
        origin.x = max(0, min(
            origin.x - event.scrollingDeltaY,
            strip.frame.width - contentView.bounds.width
        ))
        contentView.setBoundsOrigin(origin)
        reflectScrolledClipView(contentView)
    }
}

/// Screen-level registry of live tab strips, for cross-strip drop
/// hit-testing during a tear-off drag (other windows and this window's
/// other pane alike).
@MainActor
final class TabStripRegistry {
    static let shared = TabStripRegistry()

    private struct Entry {
        weak var strip: TabStripNSView?
    }

    private var entries: [TabStripID: Entry] = [:]

    func register(_ strip: TabStripNSView, for stripID: TabStripID) {
        entries[stripID] = Entry(strip: strip)
    }

    func unregister(stripID: TabStripID) {
        entries[stripID] = nil
    }

    /// The strip whose screen rect (with a small vertical grace band)
    /// contains the point, frontmost window first.
    func strip(at screenPoint: CGPoint) -> (TabStripID, TabStripNSView)? {
        // Respect z-order: check windows front-to-back.
        for window in NSApp.orderedWindows {
            let inWindow = entries.filter { $0.value.strip?.window === window }
            for (id, entry) in inWindow {
                guard let strip = entry.strip, let stripWindow = strip.window else { continue }
                // Hit-test the VISIBLE part (the clip view), not the
                // scrolled document.
                let container: NSView = strip.enclosingScrollView ?? strip
                var rect = container.convert(container.bounds, to: nil)
                rect = stripWindow.convertToScreen(rect)
                let graceRect = rect.insetBy(dx: 0, dy: -TabStripNSView.tearOffDistance / 2)
                if graceRect.contains(screenPoint) {
                    return (id, strip)
                }
            }
        }
        return nil
    }

    /// Highlights the strip under the pointer during a tear-off drag.
    func updateDropTarget(at screenPoint: CGPoint?, excluding: TabStripID?) {
        let target = screenPoint.flatMap { strip(at: $0) }
        for (id, entry) in entries {
            entry.strip?.setDropTargetHighlight(target?.0 == id && id != excluding)
        }
    }
}

/// Borderless floating ghost that follows the pointer during a tear-off.
@MainActor
final class TabGhostPanel: NSPanel {
    private let grabOffset: CGPoint

    init(snapshotting view: NSView) {
        let size = view.bounds.size == .zero
            ? CGSize(width: 160, height: TabStripNSView.stripHeight)
            : view.bounds.size
        grabOffset = CGPoint(x: size.width / 2, y: size.height / 2)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        alphaValue = 0.85

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(rep)
            imageView.image = image
        }
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageView.layer?.cornerRadius = 4
        contentView = imageView
        orderFrontRegardless()
    }

    func move(to screenPoint: CGPoint) {
        setFrameOrigin(CGPoint(
            x: screenPoint.x - grabOffset.x,
            y: screenPoint.y - grabOffset.y
        ))
    }
}

private extension NSRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// NSMenuItem action plumbing without @objc selector targets per item.
@MainActor
private final class MenuHandler: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

@MainActor
private extension NSMenuItem {
    func setHandler(_ handler: @escaping () -> Void) {
        let boxed = MenuHandler(handler)
        target = boxed
        action = #selector(MenuHandler.fire)
        // NSMenuItem does not retain its target; anchor the handler here.
        representedObject = boxed
    }
}

#endif
