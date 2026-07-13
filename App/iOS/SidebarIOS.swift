import PDFKit
import ReaderCore
import ReaderUI
import SwiftUI

/// Reader sidebar for iOS: table of contents + bookmarks, with a filter
/// field that fuzzy-matches section paths (the ⌘P in-book palette's job on
/// macOS). Regular width shows it as a panel; compact presents it as a
/// sheet (`onNavigate` dismisses after a jump).
///
/// Follow mode is always on (macOS's toggle can come later): the section
/// containing the reading position stays highlighted, its ancestors
/// auto-expand, and the list scrolls to keep it visible.
struct SidebarIOS: View {
    let model: ReaderSessionModel
    @Bindable var chrome: ReaderChromeModel
    let palette: DesignPalette
    var onNavigate: (() -> Void)?

    @State private var filter = ""
    @State private var expanded: Set<UUID> = []
    /// Follow the reading position: keep only the current section's ancestor
    /// path expanded and scroll it into view. Off = free manual browsing.
    /// Persisted (and shared between the iPad panel and iPhone sheet) so the
    /// choice survives relaunch.
    @AppStorage("ReaderSidebarFollowSection") private var followSection = true
    @State private var findQuery = ""
    @State private var findController = FindController()
    @FocusState private var findFieldFocused: Bool

    private var mode: SidebarMode { chrome.sidebarMode }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color(platformColor: palette.sidebarBorder))
            switch mode {
            case .contents:
                if filter.isEmpty {
                    outlineTree
                } else {
                    filteredList
                }
            case .bookmarks:
                bookmarkList
            case .find:
                findResults
            }
        }
        .background(Color(platformColor: palette.sidebarBackground))
        .onChange(of: mode, initial: true) { _, newMode in
            if newMode == .find {
                findFieldFocused = true
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Picker("Sidebar mode", selection: $chrome.sidebarMode) {
                ForEach(SidebarMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            if mode == .find {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color(platformColor: palette.textMuted))
                    TextField("Find in document", text: $findQuery)
                        .textFieldStyle(.plain)
                        .focused($findFieldFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !findQuery.isEmpty {
                        Button {
                            findQuery = ""
                            findController.cancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color(platformColor: palette.textMuted))
                        }
                        .accessibilityLabel("Clear search")
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(platformColor: palette.ink).opacity(0.06))
                )
                .onChange(of: findQuery) { _, query in
                    // Streaming find; typing never navigates (macOS rule).
                    if let document = model.activeDocument {
                        findController.search(query, in: document)
                    }
                }
            }
            if mode == .contents {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(Color(platformColor: palette.textMuted))
                        TextField("Filter sections", text: $filter)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !filter.isEmpty {
                            Button {
                                filter = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color(platformColor: palette.textMuted))
                            }
                            .accessibilityLabel("Clear filter")
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(platformColor: palette.ink).opacity(0.06))
                    )
                    // Follow the current chapter as you scroll (macOS
                    // crosshair toggle): collapses everything but the
                    // current section's path and keeps it in view.
                    Button {
                        followSection.toggle()
                    } label: {
                        Image(systemName: followSection
                            ? "scope" : "circle.dashed")
                            .foregroundStyle(Color(platformColor:
                                followSection ? palette.accent : palette.textMuted))
                    }
                    .accessibilityLabel(followSection
                        ? "Following current section" : "Follow current section")
                    .hoverEffect(.highlight)
                }
            } else if mode == .bookmarks {
                Button {
                    model.addBookmarkAtCurrentPosition()
                } label: {
                    Label("Bookmark This Page", systemImage: "bookmark.fill")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.activeTabID == nil)
            }
        }
        .padding(10)
    }

    // MARK: - Contents tree

    private var outlineTree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.outlineNodes) { node in
                        outlineRow(node, depth: 0)
                    }
                }
                .padding(.vertical, 6)
            }
            .onAppear { revealCurrent(with: proxy) }
            .onChange(of: model.currentSectionStop?.nodeID) { _, _ in
                revealCurrent(with: proxy)
            }
            .onChange(of: followSection) { _, on in
                if on { revealCurrent(with: proxy) }
            }
        }
    }

    /// Follow mode: collapse everything EXCEPT the current section's
    /// ancestor path (expanded exactly enough to reveal it) and scroll it
    /// into view. When following is off, expansion is the user's to manage.
    private func revealCurrent(with proxy: ScrollViewProxy) {
        guard followSection, let stop = model.currentSectionStop else { return }
        let ancestors = OutlineNode.ancestorIDs(of: stop.nodeID, in: model.outlineNodes)
        withAnimation(.easeInOut(duration: 0.2)) {
            expanded = Set(ancestors)
            proxy.scrollTo(stop.nodeID, anchor: .center)
        }
    }

    @ViewBuilder
    private func outlineRow(_ node: OutlineNode, depth: Int) -> AnyView {
        let hasChildren = !(node.children?.isEmpty ?? true)
        let isExpanded = expanded.contains(node.id)
        let isCurrent = node.id == model.currentSectionStop?.nodeID

        return AnyView(VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if hasChildren {
                    Button {
                        // Manual expansion means the reader wants to browse:
                        // stop auto-collapsing behind them.
                        followSection = false
                        if isExpanded {
                            expanded.remove(node.id)
                        } else {
                            expanded.insert(node.id)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(Color(platformColor: palette.textMuted))
                            .frame(width: 18, height: 18)
                    }
                    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
                } else {
                    Color.clear.frame(width: 18, height: 18)
                }
                sectionButton(
                    label: node.label, entry: node.entry, isCurrent: isCurrent
                )
            }
            .padding(.leading, CGFloat(depth) * 14)
            .id(node.id)
            if hasChildren, isExpanded {
                ForEach(node.children ?? []) { child in
                    outlineRow(child, depth: depth + 1)
                }
            }
        })
    }

    // MARK: - Filtered (flat) list — the ⌘P replacement

    private struct FilterHit: Identifiable {
        let id: UUID
        let label: String
        let breadcrumb: String
        let entry: NavEntry
        let score: Int
    }

    private var filterHits: [FilterHit] {
        var hits: [FilterHit] = []
        func walk(_ nodes: [OutlineNode], ancestors: [String]) {
            for node in nodes {
                let path = ancestors + [node.label]
                if let entry = node.entry,
                   let match = FuzzyMatcher.match(
                    query: filter, in: path.joined(separator: " ")) {
                    hits.append(FilterHit(
                        id: node.id, label: node.label,
                        breadcrumb: ancestors.joined(separator: " › "),
                        entry: entry, score: match.score
                    ))
                }
                walk(node.children ?? [], ancestors: path)
            }
        }
        walk(model.outlineNodes, ancestors: [])
        return hits.sorted { $0.score > $1.score }
    }

    private var filteredList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if filterHits.isEmpty {
                    Text("No matching sections")
                        .font(.subheadline)
                        .foregroundStyle(Color(platformColor: palette.textMuted))
                        .padding(12)
                } else {
                    ForEach(filterHits) { hit in
                        VStack(alignment: .leading, spacing: 1) {
                            sectionButton(
                                label: hit.label, entry: hit.entry, isCurrent: false)
                            if !hit.breadcrumb.isEmpty {
                                Text(hit.breadcrumb)
                                    .font(.caption2)
                                    .foregroundStyle(Color(platformColor: palette.textMuted))
                                    .lineLimit(1)
                                    .padding(.leading, 10)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// One tappable section: tap = jump (history push), long-press = open
    /// elsewhere, drag = drop on the strip or split zone.
    private func sectionButton(
        label: String, entry: NavEntry?, isCurrent: Bool
    ) -> some View {
        Button {
            guard let entry else { return }
            model.jump(to: entry)
            onNavigate?()
        } label: {
            Text(label.isEmpty ? "Untitled" : label)
                .font(.subheadline)
                .foregroundStyle(Color(platformColor:
                    isCurrent ? palette.accent : palette.textPrimary))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isCurrent
                            ? Color(platformColor: palette.accentSoft)
                            : .clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(entry == nil)
        .contextMenu {
            if let entry {
                Button {
                    guard let url = model.activeURL else { return }
                    model.openTab(url: url, at: entry, activate: false)
                } label: {
                    Label("Open in New Tab", systemImage: "plus.rectangle.on.rectangle")
                }
                if UIDevice.current.userInterfaceIdiom == .pad {
                    Button {
                        model.openEntryInSplit(entry)
                    } label: {
                        Label("Open in Split", systemImage: "rectangle.split.2x1")
                    }
                }
            }
        }
        .draggable(entry.map { DragPayload.section($0) } ?? "")
    }

    // MARK: - Find results (in-document search — the macOS search sidebar)

    private var findResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if findController.isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(12)
                } else if findQuery.isEmpty {
                    Text("Search the current book.")
                        .font(.subheadline)
                        .foregroundStyle(Color(platformColor: palette.textMuted))
                        .padding(12)
                } else if findController.didSearch, findController.matches.isEmpty {
                    Text("No matches for “\(findQuery)”.")
                        .font(.subheadline)
                        .foregroundStyle(Color(platformColor: palette.textMuted))
                        .padding(12)
                } else {
                    ForEach(
                        Array(findController.matches.enumerated()), id: \.offset
                    ) { _, match in
                        findRow(match)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func findRow(_ match: PDFSelection) -> some View {
        Button {
            model.jumpToFindResult(match)
            onNavigate?()
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(match.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "Match")
                    .font(.subheadline)
                    .foregroundStyle(Color(platformColor: palette.textPrimary))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                if let page = match.pages.first,
                   let document = model.activeDocument {
                    Text("p.\(document.index(for: page) + 1)")
                        .font(.caption)
                        .foregroundStyle(Color(platformColor: palette.textMuted))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bookmarks

    private var bookmarkList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.activeBookmarks.isEmpty {
                    Text("No bookmarks in this book yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color(platformColor: palette.textMuted))
                        .padding(12)
                } else {
                    ForEach(model.activeBookmarks, id: \.id) { bookmark in
                        HStack {
                            Button {
                                model.jump(to: NavEntry(pageIndex: bookmark.page))
                                onNavigate?()
                            } label: {
                                Label {
                                    Text(bookmark.label ?? "Page \(bookmark.page + 1)")
                                        .font(.subheadline)
                                        .foregroundStyle(
                                            Color(platformColor: palette.textPrimary))
                                } icon: {
                                    Image(systemName: "bookmark")
                                        .foregroundStyle(
                                            Color(platformColor: palette.accent))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Text("p.\(bookmark.page + 1)")
                                .font(.caption)
                                .foregroundStyle(Color(platformColor: palette.textMuted))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contextMenu {
                            Button(role: .destructive) {
                                if let id = bookmark.id {
                                    model.deleteBookmark(id)
                                }
                            } label: {
                                Label("Delete Bookmark", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}
