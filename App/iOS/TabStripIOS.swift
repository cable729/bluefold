import PDFKit
import ReaderCore
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

/// Drag payloads for the strip and split drop zone, encoded as prefixed
/// plain-text strings (a custom UTType would need an exported Info.plist
/// declaration; these never leave the app).
enum DragPayload {
    static let tabPrefix = "bluefold-tab:"
    static let sectionPrefix = "bluefold-section:"
    static let bookPrefix = "bluefold-book:"

    static func tab(_ id: UUID) -> String {
        tabPrefix + id.uuidString
    }

    /// A library book being dragged onto a sidebar tag/collection.
    static func book(_ itemID: String) -> String {
        bookPrefix + itemID
    }

    static func decodeBook(_ string: String) -> String? {
        guard string.hasPrefix(bookPrefix) else { return nil }
        return String(string.dropFirst(bookPrefix.count))
    }

    static func section(_ entry: NavEntry) -> String {
        let x = entry.point.map { "\($0.x)" } ?? ""
        let y = entry.point.map { "\($0.y)" } ?? ""
        return "\(sectionPrefix)\(entry.pageIndex):\(x):\(y)"
    }

    static func decodeTab(_ string: String) -> UUID? {
        guard string.hasPrefix(tabPrefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(tabPrefix.count)))
    }

    static func decodeSection(_ string: String) -> NavEntry? {
        guard string.hasPrefix(sectionPrefix) else { return nil }
        let parts = String(string.dropFirst(sectionPrefix.count)).split(
            separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let page = Int(parts[0]) else { return nil }
        var point: CGPoint?
        if let x = Double(parts[1]), let y = Double(parts[2]) {
            point = CGPoint(x: x, y: y)
        }
        return NavEntry(pageIndex: page, point: point)
    }
}

/// One tab cell's horizontal midpoint in strip-content space.
struct TabMid: Equatable {
    let id: UUID
    let midX: CGFloat
}

/// Collects every tab cell's midpoint so the strip can place the insertion
/// bar and compute a drop's landing index.
struct TabMidKey: PreferenceKey {
    static let defaultValue: [TabMid] = []
    static func reduce(value: inout [TabMid], nextValue: () -> [TabMid]) {
        value.append(contentsOf: nextValue())
    }
}

/// Strip-level drop handling: a dragged tab shows an insertion bar at the
/// nearest gap and reorders there on release; a dragged sidebar section
/// opens a new tab at that gap.
struct TabStripDropDelegate: DropDelegate {
    let mids: [TabMid]
    @Binding var insertionX: CGFloat?
    let onReorder: (UUID, Int) -> Void
    let onSection: (NavEntry, Int) -> Void

    func dropEntered(info: DropInfo) { insertionX = barX(for: index(at: info.location.x)) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertionX = barX(for: index(at: info.location.x))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { insertionX = nil }

    func performDrop(info: DropInfo) -> Bool {
        let landing = index(at: info.location.x)
        insertionX = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            Task { @MainActor in
                if let id = DragPayload.decodeTab(payload) {
                    onReorder(id, landing)
                } else if let entry = DragPayload.decodeSection(payload) {
                    onSection(entry, landing)
                }
            }
        }
        return true
    }

    /// Insertion index = how many cells sit left of the finger.
    private func index(at x: CGFloat) -> Int {
        mids.filter { $0.midX < x }.count
    }

    /// X of the insertion bar for a landing index — the gap between
    /// neighbours, or just past the ends.
    private func barX(for index: Int) -> CGFloat {
        guard !mids.isEmpty else { return 12 }
        if index <= 0 { return max(mids[0].midX - 46, 4) }
        if index >= mids.count { return mids[mids.count - 1].midX + 46 }
        return (mids[index - 1].midX + mids[index].midX) / 2
    }
}

/// Page-0 cover thumbnails for tab caps and the tab preview panel — the
/// iOS twin of macOS TabCoverThumbnails: rendered off-main on a private
/// PDFDocument (never the shared LRU's), cached by path.
enum TabCoverThumbIOS {
    private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()

    @MainActor private static var inFlight: Set<String> = []

    static func cached(forPath path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }

    /// Renders (or returns cached) page-0 thumbnail ~`height` points tall.
    @MainActor
    static func thumbnail(forPath path: String, height: CGFloat = 120) async -> UIImage? {
        if let cached = cached(forPath: path) { return cached }
        guard !inFlight.contains(path) else { return nil }
        inFlight.insert(path)
        defer { inFlight.remove(path) }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)),
                  let page = document.page(at: 0)
            else { return nil }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.height > 0 else { return nil }
            let scale = (height * 2) / bounds.height  // 2x for retina
            let size = CGSize(width: bounds.width * scale, height: height * 2)
            return page.thumbnail(of: size, for: .cropBox)
        }.value
        if let image {
            cache.setObject(image, forKey: path as NSString)
        }
        return image
    }
}

/// The Cloth & Paper tab strip, matching the macOS main app: adjacent tabs
/// of the SAME book share one tinted lozenge with the book's page-0 cover
/// as a rounded left cap; cells inside show their section breadcrumb.
/// Touch translations: tap = activate, tap the ACTIVE cell again = cover
/// preview panel (the macOS hover panel), drag = reorder, long-press =
/// context menu, drop of a sidebar section = new tab.
struct TabStripIOS: View {
    let model: ReaderSessionModel
    let palette: DesignPalette

    /// Per-tab cell midpoints (in strip-content space), for computing where
    /// a dragged tab would land and drawing the insertion bar.
    @State private var tabMids: [TabMid] = []
    /// X of the insertion bar while a tab drag hovers the strip; nil = none.
    @State private var insertionX: CGFloat?
    /// Whether the active tab has been scrolled into view for this appearance.
    /// The initial scroll is driven off the first non-empty `TabMidKey` update
    /// (cell geometry = layout is done), since `onAppear` fires too early.
    @State private var didInitialScroll = false

    var body: some View {
        // ScrollViewReader so the active tab can be scrolled into view — at
        // launch and on every selection change — otherwise a selection far
        // to the right leaves the strip parked at the start with no visible
        // indication of which tab is current.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(groups) { group in
                        TabGroupIOS(model: model, group: group, palette: palette)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .coordinateSpace(name: "strip")
                // Insertion indicator — a small accent bar showing where the
                // dragged tab will land (owner: "hard to tell what will happen").
                .overlay(alignment: .leading) {
                    if let insertionX {
                        Capsule()
                            .fill(Color(platformColor: palette.accent))
                            .frame(width: 3, height: 34)
                            .position(x: insertionX, y: 22)
                    }
                }
                .onPreferenceChange(TabMidKey.self) { mids in
                    tabMids = mids.sorted { $0.midX < $1.midX }
                    // First real layout: bring the restored active tab into
                    // view. onAppear fires before the cells are laid out, so
                    // scrollTo there is a no-op — the midpoints arriving is
                    // the signal that the strip has a geometry to scroll to.
                    if !didInitialScroll, !mids.isEmpty, model.activeTabID != nil {
                        didInitialScroll = true
                        scrollToActive(proxy, animated: false)
                    }
                }
                .onDrop(of: [.text], delegate: TabStripDropDelegate(
                    mids: tabMids,
                    insertionX: $insertionX,
                    onReorder: { model.moveTab(id: $0, toIndex: $1) },
                    onSection: { entry, index in
                        guard let url = model.activeURL else { return }
                        model.openTab(url: url, at: entry, insertAt: index, activate: false)
                    }
                ))
            }
            // Color subviews (dividers, cover placeholders) have no intrinsic
            // height — without a hard cap the horizontal scroller goes greedy
            // and the strip fills the screen.
            .frame(height: 50)
            .background(Color(platformColor: palette.stripBackground))
            // Tabs fade out under the edges when the strip overflows (desktop
            // parity), so a partially-scrolled tab looks clipped, not cut.
            .overlay(alignment: .leading) { edgeFade(leading: true) }
            .overlay(alignment: .trailing) { edgeFade(leading: false) }
            .onChange(of: model.activeTabID) { _, _ in
                scrollToActive(proxy, animated: true)
            }
        }
    }

    /// Bring the active tab into view — centered when possible, clamped to
    /// the ends otherwise. The initial (post-restore) scroll is unanimated
    /// and deferred: a synchronous scrollTo during first layout loses to the
    /// ScrollView settling its own offset back to 0, so hop off the layout
    /// pass before scrolling. Later selection changes animate immediately.
    private func scrollToActive(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let active = model.activeTabID else { return }
        let scroll = { proxy.scrollTo(active, anchor: .center) }
        if animated {
            withAnimation { scroll() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: scroll)
        }
    }

    private func edgeFade(leading: Bool) -> some View {
        let strip = Color(platformColor: palette.stripBackground)
        return LinearGradient(
            colors: [strip, strip.opacity(0)],
            startPoint: leading ? .leading : .trailing,
            endPoint: leading ? .trailing : .leading
        )
        .frame(width: 14)
        .allowsHitTesting(false)
    }

    /// Adjacent same-book runs, macOS round-20 grouping.
    private var groups: [TabGroup] {
        var result: [TabGroup] = []
        for tab in model.tabs {
            if var last = result.last, last.path == tab.pathHint {
                last.tabs.append(tab)
                result[result.count - 1] = last
            } else {
                result.append(TabGroup(id: tab.id, path: tab.pathHint, tabs: [tab]))
            }
        }
        return result
    }
}

struct TabGroup: Identifiable {
    let id: UUID  // first tab's id — stable enough for strip diffing
    let path: String
    var tabs: [TabState]
}

private struct TabGroupIOS: View {
    let model: ReaderSessionModel
    let group: TabGroup
    let palette: DesignPalette

    @State private var cover: UIImage?
    /// Whether the book cover-preview popover is up (tapping the cover cap).
    @State private var showingPreview = false

    private var tint: Color {
        Color(platformColor: BookTint.color(forPath: group.path))
    }

    /// The tab the preview panel represents: the group's active tab if one
    /// is active here, else its first — the panel is about the BOOK.
    private var previewTab: TabState {
        group.tabs.first { $0.id == model.activeTabID } ?? group.tabs[0]
    }

    var body: some View {
        HStack(spacing: 0) {
            coverCap
            ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    Color(platformColor: palette.lozengeDivider)
                        .frame(width: 1)
                        .padding(.vertical, 5)
                }
                cell(for: tab)
            }
        }
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.20))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: group.path) {
            if let cached = TabCoverThumbIOS.cached(forPath: group.path) {
                cover = cached
            } else {
                cover = await TabCoverThumbIOS.thumbnail(forPath: group.path)
            }
        }
    }

    /// Book page-0 as a full-height rounded left cap (macOS round 21).
    /// Tapping the cover — the "book part" — shows the preview panel for
    /// the book WITHOUT selecting the tab (the macOS hover panel); this is
    /// also where the book's name lives, since the cells show sections.
    private var coverCap: some View {
        Button {
            showingPreview = true
        } label: {
            Group {
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else {
                    tint.opacity(0.6)
                }
            }
            .frame(width: 26, height: 40)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview book")
        .popover(isPresented: $showingPreview, attachmentAnchor: .rect(.bounds)) {
            TabCoverPreviewIOS(path: group.path, tab: previewTab, palette: palette)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func cell(for tab: TabState) -> some View {
        let isActive = tab.id == model.activeTabID
        let isSplit = tab.id == model.splitTabID

        return HStack(spacing: 6) {
            Text(subtitle(for: tab))
                .font(.caption.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)  // "3.1 Conv…", keep the number
                .frame(maxWidth: 140, alignment: .leading)
            if isSplit {
                Image(systemName: "rectangle.split.2x1")
                    .font(.caption2)
                    .opacity(0.5)
            }
            if isActive {
                Button {
                    model.close(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .opacity(0.55)
                }
                .accessibilityLabel("Close tab")
                .hoverEffect(.highlight)
            }
        }
        .foregroundStyle(Color(platformColor: palette.ink))
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(
            isActive
                ? Color(platformColor: palette.activeCellFill)
                : .clear
        )
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .onTapGesture {
            // The text cell selects; the book cover cap shows the preview.
            model.activate(tab.id)
        }
        .contextMenu {
            Button {
                model.duplicate(tab.id)
            } label: {
                Label("Duplicate Tab", systemImage: "plus.square.on.square")
            }
            if UIDevice.current.userInterfaceIdiom == .pad {
                Button {
                    model.openInSplit(tabID: tab.id, axis: .horizontal)
                } label: {
                    Label("Open in Split", systemImage: "rectangle.split.2x1")
                }
                Button {
                    model.openInSplit(tabID: tab.id, axis: .vertical)
                } label: {
                    Label("Split Bottom", systemImage: "rectangle.split.1x2")
                }
            } else {
                Button {
                    model.openInSplit(tabID: tab.id, axis: .vertical)
                } label: {
                    Label("Split Bottom", systemImage: "rectangle.split.1x2")
                }
            }
            Divider()
            Button(role: .destructive) {
                model.close(tab.id)
            } label: {
                Label("Close Tab", systemImage: "xmark")
            }
            Button(role: .destructive) {
                model.closeTabs(leftOf: tab.id)
            } label: {
                Label("Close Tabs to the Left", systemImage: "arrow.left.to.line")
            }
            .disabled(!model.canCloseTabs(leftOf: tab.id))
            Button(role: .destructive) {
                model.closeTabs(rightOf: tab.id)
            } label: {
                Label("Close Tabs to the Right", systemImage: "arrow.right.to.line")
            }
            .disabled(!model.canCloseTabs(rightOf: tab.id))
            Button(role: .destructive) {
                model.closeOthers(keeping: tab.id)
            } label: {
                Label("Close Other Tabs", systemImage: "xmark.square")
            }
        }
        .draggable(DragPayload.tab(tab.id))
        // Explicit scroll anchor: cells live inside this nested group view, so
        // ScrollViewReader can't rely on ForEach's implicit identity to find
        // the active tab — scrollTo(tab.id) needs a matching .id() to target.
        .id(tab.id)
        // Report this cell's midpoint so the strip can place the insertion
        // bar and compute a drop's landing index (reorder is handled at the
        // strip level, not per cell — the group lozenge clips overlays).
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TabMidKey.self,
                    value: [TabMid(id: tab.id, midX: proxy.frame(in: .named("strip")).midX)]
                )
            }
        )
    }

    /// Section breadcrumb (deepest component), falling back to the page.
    /// The book's NAME lives on the cover cap + preview panel, like macOS.
    private func subtitle(for tab: TabState) -> String {
        if let crumb = tab.breadcrumb,
           let deepest = crumb.components(separatedBy: " › ").last,
           !deepest.isEmpty {
            return deepest
        }
        return "p.\(tab.pageIndex + 1)"
    }
}

/// The macOS hover panel, summoned by tapping the current tab: enlarged
/// cover + book title + position.
private struct TabCoverPreviewIOS: View {
    let path: String
    let tab: TabState
    let palette: DesignPalette

    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color(platformColor: BookTint.color(forPath: path)).opacity(0.4)
                }
            }
            .frame(width: 84, height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text(((path as NSString).lastPathComponent as NSString)
                    .deletingPathExtension)
                    .font(.headline)
                    .lineLimit(3)
                if let crumb = tab.breadcrumb, !crumb.isEmpty {
                    Text(crumb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text("p.\(tab.pageIndex + 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .padding(14)
        .task {
            cover = await TabCoverThumbIOS.thumbnail(forPath: path)
        }
    }
}
