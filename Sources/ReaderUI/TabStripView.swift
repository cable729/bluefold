#if os(macOS)
import AppKit
import ReaderCore

/// What the strip needs to know about one tab to draw it.
struct TabDisplayItem: Equatable {
    let id: UUID
    let title: String
    /// Second row: outline breadcrumb of the tab's position (may be a plain
    /// page label for outline-less documents).
    let breadcrumb: String
    let isActive: Bool
    /// Whether this tab is currently shown in the split pane.
    var isSplit = false
    /// Adjacent tabs with the same key render as a group: the title shown
    /// once in a header spanning the run, breadcrumbs per tab beneath.
    let groupKey: String
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
    var openInSplit: (UUID) -> Void = { _ in }
    var closeSplit: () -> Void = {}
    var reorder: (UUID, Int) -> Void
    /// Cross-window move: (tabID, targetWindowID, insertionIndex)
    var moveToWindow: (UUID, UUID, Int) -> Void
    /// Tab dropped on empty desktop at a screen point.
    var detachToNewWindow: (UUID, CGPoint) -> Void
}

/// AppKit-backed, Chrome-style tab strip. SwiftUI's .draggable/.onTapGesture
/// combination proved unreliable for tab dragging (gesture conflicts, no way
/// to detect desktop drops), so the strip tracks the mouse itself:
///   - horizontal drag inside the strip band → live reorder preview, commit
///     on mouse-up
///   - drag beyond ±`Self.tearOffDistance` vertically → tear-off: a ghost
///     panel follows the pointer; dropping over another window's strip moves
///     the tab there, dropping anywhere else opens a new window at the point.
/// Cross-window hit-testing goes through `TabStripRegistry`.
///
/// Tabs render two rows — title, then the outline breadcrumb of that tab's
/// position. Adjacent tabs of the same book render the title once in a
/// header spanning the run (a real tab group), breadcrumbs per tab beneath.
/// While a drag is in flight everything renders as singletons so slot math
/// stays trivial.
@MainActor
final class TabStripNSView: NSView {
    static let tabHeight: CGFloat = 48
    static let groupHeaderHeight: CGFloat = 17
    static let minTabWidth: CGFloat = 60
    static let maxTabWidth: CGFloat = 220
    static let tearOffDistance: CGFloat = 44

    let windowID: UUID
    var actions: TabStripActions

    private(set) var items: [TabDisplayItem] = []
    private var itemViews: [TabItemNSView] = []
    private var headerViews: [TabGroupHeaderView] = []
    private var drag: DragState?

    /// Multi-selection for bulk actions (⌘-click toggles, ⇧-click extends
    /// from the active tab). Purely view state; cleared by plain clicks and
    /// content changes.
    private(set) var multiSelection: Set<UUID> = []

    /// Highlight shown while a foreign tab drag hovers over this strip.
    private var isDropTarget = false {
        didSet { needsDisplay = (isDropTarget != oldValue) || needsDisplay }
    }

    init(windowID: UUID, actions: TabStripActions) {
        self.windowID = windowID
        self.actions = actions
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("tab-strip")
        setAccessibilityEnabled(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            TabStripRegistry.shared.register(self, for: windowID)
        } else {
            TabStripRegistry.shared.unregister(windowID: windowID)
        }
    }

    // MARK: - Content

    func update(items: [TabDisplayItem]) {
        guard items != self.items else { return }
        self.items = items

        // Reuse views by tab ID so hover state survives reorders.
        var existing: [UUID: TabItemNSView] = [:]
        for view in itemViews { existing[view.tabID] = view }
        itemViews = items.map { item in
            let view = existing.removeValue(forKey: item.id)
                ?? TabItemNSView(tabID: item.id, owner: self)
            view.apply(item)
            if view.superview !== self { addSubview(view) }
            return view
        }
        for (_, orphan) in existing { orphan.removeFromSuperview() }

        // Selection can only reference live tabs.
        let live = Set(items.map(\.id))
        multiSelection.formIntersection(live)
        applyMultiSelectionChrome()
        needsLayout = true
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.tabHeight)
    }

    override func layout() {
        super.layout()
        layoutItems(animated: false)
    }

    /// Shrink-to-fit layout (no scrolling; browsers shrink tabs instead).
    /// During a drag the dragged tab tracks the pointer and others make room.
    private func layoutItems(animated: Bool) {
        guard !itemViews.isEmpty else {
            clearHeaders()
            return
        }
        let width = tabWidth
        let ordered = orderedViewsForLayout()

        // Group runs of adjacent same-book tabs — suspended during a drag,
        // where slot math must stay per-tab.
        let grouped: [Range<Int>] = drag == nil ? groupRuns(in: ordered) : []
        var isGrouped = [ObjectIdentifier: Bool]()
        for run in grouped {
            for index in run {
                if let item = ordered[index] as? TabItemNSView {
                    isGrouped[ObjectIdentifier(item)] = true
                }
            }
        }

        for (slot, view) in ordered.enumerated() {
            let inGroup = isGrouped[ObjectIdentifier(view)] == true
            let height = inGroup ? bounds.height - Self.groupHeaderHeight : bounds.height
            let target = NSRect(
                x: CGFloat(slot) * width, y: 0,
                width: width, height: height
            )
            (view as? TabItemNSView)?.setGrouped(inGroup)
            if view === drag?.itemView, drag?.isTornOff == false {
                // The dragged tab follows the pointer horizontally.
                var f = target
                f.origin.x = drag!.currentTabOriginX(tabWidth: width, stripWidth: bounds.width)
                view.frame = f
            } else if animated {
                view.animator().frame = target
            } else {
                view.frame = target
            }
        }

        layoutHeaders(runs: grouped, ordered: ordered, tabWidth: width, animated: animated)
    }

    /// Ranges of adjacent visible tabs sharing a groupKey (length ≥ 2).
    private func groupRuns(in ordered: [NSView]) -> [Range<Int>] {
        let keys: [String?] = ordered.map { view in
            guard let item = view as? TabItemNSView else { return nil }
            return items.first { $0.id == item.tabID }?.groupKey
        }
        guard !keys.isEmpty else { return [] }
        var runs: [Range<Int>] = []
        var start = 0
        for index in 1...keys.count {
            if index == keys.count || keys[index] == nil || keys[index] != keys[start] {
                if index - start >= 2, keys[start] != nil {
                    runs.append(start..<index)
                }
                start = index
            }
        }
        return runs
    }

    private func layoutHeaders(
        runs: [Range<Int>], ordered: [NSView], tabWidth: CGFloat, animated: Bool
    ) {
        // Reuse header views positionally; runs are few.
        while headerViews.count > runs.count {
            headerViews.removeLast().removeFromSuperview()
        }
        while headerViews.count < runs.count {
            let header = TabGroupHeaderView(owner: self)
            headerViews.append(header)
            addSubview(header)
        }
        for (header, run) in zip(headerViews, runs) {
            let firstTab = (ordered[run.lowerBound] as? TabItemNSView)
            let title = firstTab.flatMap { view in
                items.first { $0.id == view.tabID }?.title
            } ?? ""
            header.apply(title: title, firstTabID: firstTab?.tabID)
            let frame = NSRect(
                x: CGFloat(run.lowerBound) * tabWidth,
                y: bounds.height - Self.groupHeaderHeight,
                width: CGFloat(run.count) * tabWidth,
                height: Self.groupHeaderHeight
            )
            if animated {
                header.animator().frame = frame
            } else {
                header.frame = frame
            }
        }
    }

    private func clearHeaders() {
        for header in headerViews { header.removeFromSuperview() }
        headerViews.removeAll()
    }

    private var tabWidth: CGFloat {
        let visible = CGFloat(max(itemViews.filter { !$0.isHidden }.count, 1))
        return max(Self.minTabWidth, min(Self.maxTabWidth, bounds.width / visible))
    }

    /// Item views in visual order: model order, adjusted by the in-flight
    /// drag preview (dragged tab occupies its provisional slot).
    private func orderedViewsForLayout() -> [NSView] {
        guard let drag, !drag.isTornOff else {
            return itemViews.filter { !$0.isHidden }
        }
        var views = itemViews.filter { $0 !== drag.itemView }
        let slot = max(0, min(drag.previewIndex, views.count))
        views.insert(drag.itemView, at: slot)
        return views
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
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

    /// Temporary drag diagnostics (PDFREADER_SESSION_DIR/dragdebug.log);
    /// active only when the session-dir override is present, i.e. tests.
    static func dragLog(_ message: String) {
        guard let dir = ProcessInfo.processInfo.environment["PDFREADER_SESSION_DIR"] else { return }
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
            && inStrip.x < bounds.width + Self.tearOffDistance
        if inBand {
            if drag.isTornOff { // re-entered: dissolve the ghost
                drag.ghost?.close()
                drag.ghost = nil
                drag.isTornOff = false
                drag.itemView.isHidden = false
            }
            // Provisional slot from the tab's midpoint.
            let midX = drag.currentTabOriginX(tabWidth: tabWidth, stripWidth: bounds.width)
                + tabWidth / 2
            drag.previewIndex = max(0, min(Int(midX / tabWidth), itemViews.count - 1))
            self.drag = drag
            layoutItems(animated: true)
        } else {
            if !drag.isTornOff {
                drag.isTornOff = true
                drag.itemView.isHidden = true
                drag.ghost = TabGhostPanel(snapshotting: drag.itemView)
                layoutItems(animated: true) // remaining tabs close the gap
            }
            let screen = screenPoint(for: event)
            drag.ghost?.move(to: screen)
            self.drag = drag
            // Light up whichever strip would accept the drop.
            TabStripRegistry.shared.updateDropTarget(
                at: screen, excluding: drag.isTornOff ? nil : windowID
            )
        }
    }

    func endPress(with event: NSEvent) {
        Self.dragLog("endPress loc=\(event.locationInWindow) drag=\(drag.map { "didMove=\($0.didMove) tornOff=\($0.isTornOff)" } ?? "nil")")
        guard let drag else { return }
        defer {
            self.drag = nil
            TabStripRegistry.shared.updateDropTarget(at: nil, excluding: nil)
            layoutItems(animated: true)
        }
        drag.ghost?.close()
        drag.itemView.isHidden = false

        guard drag.didMove else { return } // plain click; select already ran

        if drag.isTornOff {
            let screen = screenPoint(for: event)
            if let (targetID, targetStrip) = TabStripRegistry.shared.strip(at: screen) {
                if targetID == windowID {
                    return // dropped back on our own strip: no-op
                }
                let index = targetStrip.insertionIndex(forScreenPoint: screen)
                actions.moveToWindow(drag.tabID, targetID, index)
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
        guard tabWidth > 0 else { return items.count }
        return max(0, min(Int((inStrip.x / tabWidth).rounded()), items.count))
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
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Bulk action when the right-clicked tab is part of a multi-selection.
        if multiSelection.count > 1, multiSelection.contains(item.tabID) {
            let ids = items.map(\.id).filter { multiSelection.contains($0) }
            menu.addItem(
                withTitle: "Close \(ids.count) Tabs", action: nil, keyEquivalent: ""
            ).setHandler { [weak self] in self?.actions.closeMany(ids) }
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Duplicate Tab", action: nil, keyEquivalent: "")
            .setHandler { [weak self] in self?.actions.duplicate(item.tabID) }
        if items.first(where: { $0.id == item.tabID })?.isSplit == true {
            menu.addItem(withTitle: "Close Split View", action: nil, keyEquivalent: "")
                .setHandler { [weak self] in self?.actions.closeSplit() }
        } else {
            let split = menu.addItem(
                withTitle: "Open in Split View", action: nil, keyEquivalent: ""
            )
            split.setHandler { [weak self] in self?.actions.openInSplit(item.tabID) }
            split.isEnabled = items.count > 1
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab", action: nil, keyEquivalent: "")
            .setHandler { [weak self] in self?.actions.close(item.tabID) }
        let closeOthers = menu.addItem(
            withTitle: "Close Other Tabs", action: nil, keyEquivalent: ""
        )
        closeOthers.setHandler { [weak self] in self?.actions.closeOthers(item.tabID) }
        closeOthers.isEnabled = items.count > 1
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to New Window", action: nil, keyEquivalent: "")
            .setHandler { [weak self] in
                guard let self else { return }
                let below = self.window?.frame.center ?? .zero
                self.actions.detachToNewWindow(item.tabID, below)
            }
        return menu
    }
}

/// One tab in the strip: title row + breadcrumb row. When part of a group
/// the title row is hidden (the spanning header carries it) and the
/// breadcrumb centers in the remaining height. Pure display + event
/// forwarding; all decisions live in the owning strip.
@MainActor
final class TabItemNSView: NSView {
    let tabID: UUID
    private unowned let owner: TabStripNSView

    private let titleField = NSTextField(labelWithString: "")
    private let breadcrumbField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let activeBar = NSView()
    private let textStack = NSStackView()
    private var isActive = false
    private var isGrouped = false
    private var isMultiSelected = false
    private var isHovered = false { didSet { refreshChrome() } }
    private var trackingArea: NSTrackingArea?

    init(tabID: UUID, owner: TabStripNSView) {
        self.tabID = tabID
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true

        titleField.font = .systemFont(ofSize: 12)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.setAccessibilityIdentifier("tab-title")

        breadcrumbField.font = .systemFont(ofSize: 9.5)
        breadcrumbField.textColor = .tertiaryLabelColor
        // Head truncation keeps the deepest (most useful) section visible.
        breadcrumbField.lineBreakMode = .byTruncatingHead
        breadcrumbField.setAccessibilityIdentifier("tab-breadcrumb")

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.addArrangedSubview(titleField)
        textStack.addArrangedSubview(breadcrumbField)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Close Tab"
        )
        closeButton.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setAccessibilityIdentifier("tab-close")

        activeBar.wantsLayer = true
        activeBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        activeBar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textStack)
        addSubview(closeButton)
        addSubview(activeBar)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            textStack.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            activeBar.topAnchor.constraint(equalTo: topAnchor),
            activeBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            activeBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            activeBar.heightAnchor.constraint(equalToConstant: 2),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ item: TabDisplayItem) {
        titleField.stringValue = item.title
        titleField.font = .systemFont(ofSize: 12, weight: item.isActive ? .semibold : .regular)
        breadcrumbField.stringValue = item.breadcrumb
        breadcrumbField.isHidden = item.breadcrumb.isEmpty
        isActive = item.isActive
        setAccessibilityIdentifier("tab-\(item.title)")
        setAccessibilityTitle(item.title)
        refreshChrome()
    }

    /// Grouped tabs hide their title row — the group header carries it.
    func setGrouped(_ grouped: Bool) {
        guard grouped != isGrouped else { return }
        isGrouped = grouped
        titleField.isHidden = grouped
        refreshChrome()
    }

    func setMultiSelected(_ selected: Bool) {
        guard selected != isMultiSelected else { return }
        isMultiSelected = selected
        refreshChrome()
    }

    private func refreshChrome() {
        titleField.textColor = isActive ? .labelColor : .secondaryLabelColor
        breadcrumbField.textColor = isActive ? .secondaryLabelColor : .tertiaryLabelColor
        activeBar.isHidden = !isActive
        closeButton.isHidden = !(isActive || isHovered)
        layer?.backgroundColor =
            if isMultiSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            } else if isActive {
                NSColor.textBackgroundColor.cgColor
            } else if isHovered {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.2).cgColor
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

/// Title header spanning a run of same-book tabs — the tab-group affordance
/// (replaces the old colored dot). Click selects the group's first tab.
@MainActor
final class TabGroupHeaderView: NSView {
    private unowned let owner: TabStripNSView
    private let titleField = NSTextField(labelWithString: "")
    private var firstTabID: UUID?

    init(owner: TabStripNSView) {
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor
            .withAlphaComponent(0.12).cgColor
        titleField.font = .systemFont(ofSize: 10, weight: .medium)
        titleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.alignment = .center
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("tab-group-header")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(title: String, firstTabID: UUID?) {
        titleField.stringValue = title
        self.firstTabID = firstTabID
        setAccessibilityTitle(title)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if let firstTabID {
            owner.actions.select(firstTabID)
        }
    }
}

/// Screen-level registry of live tab strips, for cross-window drop
/// hit-testing during a tear-off drag.
@MainActor
final class TabStripRegistry {
    static let shared = TabStripRegistry()

    private struct Entry {
        weak var strip: TabStripNSView?
    }

    private var entries: [UUID: Entry] = [:]

    func register(_ strip: TabStripNSView, for windowID: UUID) {
        entries[windowID] = Entry(strip: strip)
    }

    func unregister(windowID: UUID) {
        entries[windowID] = nil
    }

    /// The strip whose screen rect (with a small vertical grace band)
    /// contains the point, frontmost window first.
    func strip(at screenPoint: CGPoint) -> (UUID, TabStripNSView)? {
        // Respect z-order: check windows front-to-back.
        let ordered = NSApp.orderedWindows.compactMap { window in
            entries.first { $0.value.strip?.window === window }
                .flatMap { id, entry in entry.strip.map { (id, $0) } }
        }
        for (id, strip) in ordered {
            guard let window = strip.window else { continue }
            var rect = strip.convert(strip.bounds, to: nil)
            rect = window.convertToScreen(rect)
            let graceRect = rect.insetBy(dx: 0, dy: -TabStripNSView.tearOffDistance / 2)
            if graceRect.contains(screenPoint) {
                return (id, strip)
            }
        }
        return nil
    }

    /// Highlights the strip under the pointer during a tear-off drag.
    func updateDropTarget(at screenPoint: CGPoint?, excluding: UUID?) {
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
            ? CGSize(width: 160, height: TabStripNSView.tabHeight)
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
