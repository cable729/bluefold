#if os(macOS)
import PDFKit
import ReaderCore
import ReaderPersistence
import SwiftUI

enum SidebarMode: String, CaseIterable {
    case outline
    case thumbnails
    case bookmarks
    case search

    var icon: String {
        switch self {
        case .outline: "list.bullet"
        case .thumbnails: "square.grid.2x2"
        case .bookmarks: "bookmark"
        case .search: "magnifyingglass"
        }
    }

    var help: String {
        switch self {
        case .outline: "Contents"
        case .thumbnails: "Pages"
        case .bookmarks: "Bookmarks"
        case .search: "Search (⌘F)"
        }
    }
}

/// Left sidebar of a reader window: contents / thumbnails / bookmarks /
/// search results for the active tab.
struct SidebarView: View {
    @Binding var mode: SidebarMode
    let outline: [OutlineNode]
    let document: PDFDocument
    let currentPageIndex: Int
    unowned let model: ReaderWindowModel
    @Bindable var find: FindController
    /// Incremented by ⌘F so the search field grabs focus.
    let searchFocusToken: Int

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar mode", selection: $mode) {
                ForEach(SidebarMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.icon)
                        .help(mode.help)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Group {
                switch mode {
                case .outline:
                    OutlineList(
                        outline: outline,
                        currentPageIndex: currentPageIndex,
                        onJump: { model.jump(to: $0) }
                    )
                case .thumbnails:
                    thumbnails
                case .bookmarks:
                    bookmarksList
                case .search:
                    SearchResultsList(
                        document: document,
                        model: model,
                        find: find,
                        focusToken: searchFocusToken
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
    }

    private var thumbnails: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<document.pageCount, id: \.self) { pageIndex in
                    ThumbnailCell(document: document, pageIndex: pageIndex) {
                        model.jump(to: NavEntry(pageIndex: pageIndex))
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var bookmarksList: some View {
        VStack(spacing: 0) {
            Group {
                if model.activeBookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark",
                        description: Text("Press ⌘D to bookmark the current page.")
                    )
                } else {
                    List(model.activeBookmarks, id: \.id) { bookmark in
                        BookmarkRow(
                            bookmark: bookmark,
                            jump: { model.jump(to: NavEntry(pageIndex: bookmark.page)) },
                            remove: {
                                if let id = bookmark.id {
                                    model.deleteBookmark(id: id)
                                }
                            }
                        )
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            Button {
                model.addBookmarkAtCurrentPosition()
            } label: {
                Label("Bookmark Current Page", systemImage: "bookmark.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
        }
    }
}

/// Contents list with the section containing the current page highlighted.
private struct OutlineList: View {
    let outline: [OutlineNode]
    let currentPageIndex: Int
    let onJump: (NavEntry) -> Void

    var body: some View {
        if outline.isEmpty {
            ContentUnavailableView(
                "No Table of Contents",
                systemImage: "list.bullet.indent",
                description: Text("This PDF has no outline.")
            )
        } else {
            List(outline, children: \.children) { node in
                Button {
                    if let entry = node.entry {
                        onJump(entry)
                    }
                } label: {
                    Text(node.label)
                        .lineLimit(2)
                        .fontWeight(node.id == currentNodeID ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    node.id == currentNodeID
                        ? Color.accentColor.opacity(0.18) : Color.clear
                )
            }
            .listStyle(.sidebar)
        }
    }

    /// The deepest outline entry at or before the current page.
    private var currentNodeID: UUID? {
        OutlineNode.deepestNodeID(in: outline, atOrBefore: currentPageIndex)
    }
}

private struct BookmarkRow: View {
    let bookmark: UserBookmarkRecord
    let jump: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: jump) {
            HStack {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
                    .font(.caption)
                Text(bookmark.label ?? "Page \(bookmark.page + 1)")
                    .lineLimit(1)
                Spacer()
                Text("p.\(bookmark.page + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove Bookmark", role: .destructive, action: remove)
        }
    }
}

/// In-document search: results stream in live as the user types (debounced),
/// accumulating in a list the user scans and clicks — typing never navigates
/// the document.
private struct SearchResultsList: View {
    let document: PDFDocument
    unowned let model: ReaderWindowModel
    @Bindable var find: FindController
    let focusToken: Int

    @State private var query = ""
    @State private var debounce: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Find in document", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(searchNow)
                if find.isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            if !find.matches.isEmpty {
                Text("\(find.matches.count) matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }

            Group {
                if find.matches.isEmpty, find.didSearch, !find.isSearching {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(find.matches.indices, id: \.self, selection: selectionBinding) { index in
                        let selection = find.matches[index]
                        SearchHitRow(
                            selection: selection,
                            document: document,
                            breadcrumb: breadcrumb(for: selection)
                        )
                        .tag(index)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { fieldFocused = true }
        .onDisappear { debounce?.cancel() }
        .onChange(of: focusToken) { _, _ in fieldFocused = true }
        .onChange(of: query) { _, newValue in
            // Live search: fire ~300ms after typing pauses. No navigation —
            // results just fill the list (and highlight in place).
            debounce?.cancel()
            debounce = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                startSearch(newValue)
            }
        }
        .onChange(of: find.matches.count) { _, _ in
            // Show highlights as they stream in — without moving the view.
            model.activeController?.showFindResults(find.matches, current: nil)
        }
    }

    /// Outline ancestor path of the hit's page, joined for display. Empty
    /// when the PDF has no outline (scans) — the row then omits the line.
    private func breadcrumb(for selection: PDFSelection) -> String {
        guard let page = selection.pages.first else { return "" }
        return model
            .breadcrumbPath(for: document.index(for: page), in: document)
            .joined(separator: " › ")
    }

    /// Row selection = explicit navigation (pushes history).
    private var selectionBinding: Binding<Int?> {
        Binding(
            get: { find.currentIndex },
            set: { index in
                guard let index, find.matches.indices.contains(index) else { return }
                find.select(index)
                let selection = find.matches[index]
                model.activeController?.showFindResults(find.matches, current: selection)
                guard let page = selection.pages.first else { return }
                let bounds = selection.bounds(for: page)
                model.jump(to: NavEntry(
                    pageIndex: document.index(for: page),
                    point: CGPoint(x: bounds.minX, y: bounds.maxY)
                ))
            }
        )
    }

    /// Enter still works: search immediately, skipping the debounce.
    private func searchNow() {
        debounce?.cancel()
        startSearch(query)
    }

    private func startSearch(_ query: String) {
        model.activeController?.showFindResults([], current: nil)
        find.search(query, in: document)
    }
}

private struct SearchHitRow: View {
    let selection: PDFSelection
    let document: PDFDocument
    /// Outline path of the hit's page ("Ch 1 › 1A › …"); empty = no line.
    let breadcrumb: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(context)
                .font(.callout)
                .lineLimit(2)
            HStack(spacing: 4) {
                Text("p.\(pageNumber)")
                    .monospacedDigit()
                    .layoutPriority(1)
                if !breadcrumb.isEmpty {
                    Text(breadcrumb)
                        .lineLimit(1)
                        // Keep the deepest (last) component visible.
                        .truncationMode(.middle)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var pageNumber: Int {
        guard let page = selection.pages.first else { return 0 }
        return document.index(for: page) + 1
    }

    private var context: String {
        guard let line = selection.copy() as? PDFSelection else {
            return selection.string ?? ""
        }
        line.extendForLineBoundaries()
        let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text! : (selection.string ?? "")
    }
}

private struct ThumbnailCell: View {
    let document: PDFDocument
    let pageIndex: Int
    let onTap: () -> Void

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .aspectRatio(0.77, contentMode: .fit)
                }
            }
            .frame(maxWidth: 130)
            .shadow(radius: 1)
            .onTapGesture(perform: onTap)

            Text("\(pageIndex + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task {
            guard image == nil, let page = document.page(at: pageIndex) else { return }
            image = page.thumbnail(of: CGSize(width: 130, height: 180), for: .cropBox)
        }
    }
}
#endif
