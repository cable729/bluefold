import ReaderCore
import ReaderPersistence
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI implicitly imports DeveloperToolsSupport, whose `LibraryItem`
/// (the Xcode previews library) collides with ours.
typealias LibraryItem = ReaderUI.LibraryItem

/// The overlay library on iOS: covers grid + tag/collection filtering +
/// library-wide full-text search, all backed by the shared `LibraryModel`
/// (LibraryStore for the overlay DB, IndexStore/IndexingService for FTS).
///
/// The Calibre source is the user's iCloud Drive Calibre folder, picked with
/// the system folder picker (a sandboxed app can't probe paths) — the model
/// persists a security-scoped bookmark. Calibre data stays read-only:
/// metadata.db is copied before reading, never written.
struct LibraryScreen: View {
    @Bindable var library: LibraryModel
    /// Called with a ready-to-open (local) file; the reader opens the tab.
    let onOpen: (LibraryItem, NavEntry?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingFolderPicker = false
    @State private var openError: String?
    /// Item whose context menu asked for a new tag/collection; the alert's
    /// text field creates it and immediately applies it to that book.
    @State private var newTagFor: LibraryItem?
    @State private var newTagName = ""
    @State private var newCollectionFor: LibraryItem?
    @State private var newCollectionName = ""

    private static let gridColumns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if library.needsSetup {
                    setupView
                } else {
                    content
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) { sourceMenu }
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                // Handles the security scope + bookmark persistence and
                // clears the first-run setup state.
                library.completeSetup(calibreFolder: url)
            }
        }
        .alert(
            "Couldn't Open Book",
            isPresented: Binding(
                get: { openError != nil },
                set: { if !$0 { openError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
        .alert(
            "New Tag",
            isPresented: Binding(
                get: { newTagFor != nil },
                set: { if !$0 { newTagFor = nil } }
            )
        ) {
            TextField("Tag name", text: $newTagName)
            Button("Create & Apply") {
                createTagAndApply()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "New Collection",
            isPresented: Binding(
                get: { newCollectionFor != nil },
                set: { if !$0 { newCollectionFor = nil } }
            )
        ) {
            TextField("Collection name", text: $newCollectionName)
            Button("Create & Add") {
                createCollectionAndApply()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func createTagAndApply() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let item = newTagFor else { return }
        library.createTag(name: name)
        if let tag = library.allTags.first(where: { $0.name == name }) {
            library.toggleTag(tag, for: item)
        }
        newTagName = ""
    }

    private func createCollectionAndApply() {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let item = newCollectionFor else { return }
        library.createCollection(name: name)
        if let collection = library.collections.first(where: { $0.name == name }) {
            library.toggleCollection(collection, for: item)
        }
        newCollectionName = ""
    }

    // MARK: - First-run setup

    private var setupView: some View {
        ContentUnavailableView {
            Label("Connect Your Calibre Library", systemImage: "books.vertical")
        } description: {
            Text(
                "Pick your Calibre folder in iCloud Drive (the one containing "
                    + "metadata.db). The library is read-only — this app never "
                    + "modifies it."
            )
        } actions: {
            Button("Choose Calibre Folder…") {
                showingFolderPicker = true
            }
            .buttonStyle(.borderedProminent)
            Button("Skip for Now") {
                library.completeSetup(calibreFolder: nil)
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let error = library.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if !library.textHits.isEmpty {
                    textHitsSection
                }
                grid
            }
            .padding()
        }
        .overlay {
            if library.isLoading && library.items.isEmpty {
                ProgressView("Loading library…")
            } else if !library.isLoading && library.filteredItems.isEmpty
                && library.textHits.isEmpty
            {
                emptyState
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let progress = library.indexingProgress {
                Text("Indexing for search… \(progress.done)/\(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
        .searchable(text: $library.searchText, prompt: "Search titles, tags, book text")
        .onChange(of: library.searchText) {
            // Debounced library-wide FTS over index.db; results land in
            // `textHits`.
            library.searchTextChanged()
        }
        .refreshable {
            await library.reload()
        }
        .task {
            if library.items.isEmpty {
                await library.reload()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.calibreRoot == nil {
            ContentUnavailableView {
                Label("No Calibre Folder", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose your Calibre library folder to see your books.")
            } actions: {
                Button("Choose Calibre Folder…") {
                    showingFolderPicker = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else if library.searchText.isEmpty {
            ContentUnavailableView(
                "No Books",
                systemImage: "book.closed",
                description: Text("This scope has no books yet.")
            )
        } else {
            ContentUnavailableView.search(text: library.searchText)
        }
    }

    // MARK: - Full-text hits ("In Book Text")

    private var textHitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In Book Text")
                .font(.headline)
            ForEach(library.textHits) { hit in
                Button {
                    openHit(hit)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(hit.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text("p.\(hit.page)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(plainSnippet(hit.snippet))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Divider()
        }
    }

    private func plainSnippet(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func openHit(_ hit: BookSearchHit) {
        guard let item = library.items.first(where: { $0.id == hit.itemID }) else { return }
        // Index pages are 1-based; NavEntry pages are 0-based.
        open(item, at: NavEntry(pageIndex: max(0, hit.page - 1)))
    }

    // MARK: - Grid

    private var grid: some View {
        LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 16) {
            ForEach(library.filteredItems) { item in
                cell(for: item)
            }
        }
    }

    private func cell(for item: LibraryItem) -> some View {
        Button {
            open(item, at: nil)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(item: item)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if library.downloading.contains(item.id) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.black.opacity(0.35))
                                ProgressView()
                                    .tint(.white)
                            }
                        }
                    }
                Text(item.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(item.authors.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            tagToggleMenu(for: item)
            collectionToggleMenu(for: item)
        }
    }

    /// Downloads the file from iCloud if evicted (progress shows on the
    /// cell), then hands it to the reader and dismisses.
    private func open(_ item: LibraryItem, at entry: NavEntry?) {
        Task {
            do {
                try await library.ensureLocalTracked(item)
                onOpen(item, entry)
                dismiss()
            } catch {
                openError = error.localizedDescription
            }
        }
    }

    // MARK: - Tags & collections

    private func tagToggleMenu(for item: LibraryItem) -> some View {
        Menu("Tags") {
            ForEach(library.allTags, id: \.self) { tag in
                Button {
                    library.toggleTag(tag, for: item)
                } label: {
                    if library.hasTag(tag, item: item) {
                        Label(tag.name, systemImage: "checkmark")
                    } else {
                        Text(tag.name)
                    }
                }
            }
            if !library.allTags.isEmpty {
                Divider()
            }
            Button {
                newTagFor = item
            } label: {
                Label("New Tag…", systemImage: "plus")
            }
        }
    }

    private func collectionToggleMenu(for item: LibraryItem) -> some View {
        Menu("Collections") {
            ForEach(library.collections, id: \.self) { collection in
                Button {
                    library.toggleCollection(collection, for: item)
                } label: {
                    if library.isInCollection(collection, item: item) {
                        Label(collection.name, systemImage: "checkmark")
                    } else {
                        Text(collection.name)
                    }
                }
            }
            if !library.collections.isEmpty {
                Divider()
            }
            Button {
                newCollectionFor = item
            } label: {
                Label("New Collection…", systemImage: "plus")
            }
        }
    }

    // MARK: - Filter & source menus

    private var filterMenu: some View {
        Menu {
            Picker("Scope", selection: $library.filter) {
                Label("All Books", systemImage: "books.vertical")
                    .tag(LibraryFilter.all)
                Label("Untagged (\(library.untaggedCount))", systemImage: "tag.slash")
                    .tag(LibraryFilter.untagged)
                Label(
                    "Not in Any Collection (\(library.notInAnyCollectionCount))",
                    systemImage: "square.stack.3d.up.slash"
                )
                .tag(LibraryFilter.notInAnyCollection)
                if !library.tagTree.isEmpty {
                    Section("Tags") {
                        ForEach(flattenedTags, id: \.record.self) { entry in
                            Text(indented(entry.record.name, depth: entry.depth))
                                .tag(LibraryFilter.tag(entry.record.id ?? -1))
                        }
                    }
                }
                if !library.collectionTree.isEmpty {
                    Section("Collections") {
                        ForEach(flattenedCollections, id: \.record.self) { entry in
                            Text(indented(entry.record.name, depth: entry.depth))
                                .tag(LibraryFilter.collection(entry.record.id ?? -1))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: isFiltered
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter")
    }

    private var isFiltered: Bool { library.filter != .all }

    private var flattenedTags: [(record: TagRecord, depth: Int)] {
        func flatten(_ nodes: [TagNode], depth: Int) -> [(TagRecord, Int)] {
            nodes.flatMap { [($0.tag, depth)] + flatten($0.children, depth: depth + 1) }
        }
        return flatten(library.tagTree, depth: 0)
    }

    private var flattenedCollections: [(record: CollectionRecord, depth: Int)] {
        func flatten(_ nodes: [CollectionNode], depth: Int) -> [(CollectionRecord, Int)] {
            nodes.flatMap { [($0.collection, depth)] + flatten($0.children, depth: depth + 1) }
        }
        return flatten(library.collectionTree, depth: 0)
    }

    private func indented(_ name: String, depth: Int) -> String {
        String(repeating: "    ", count: depth) + name
    }

    private var sourceMenu: some View {
        Menu {
            Button("Choose Calibre Folder…") {
                showingFolderPicker = true
            }
            if library.calibreRoot != nil {
                Button("Detach Calibre Folder", role: .destructive) {
                    library.detachCalibreFolder()
                }
            }
        } label: {
            Image(systemName: "folder")
        }
        .accessibilityLabel("Calibre folder")
    }
}

/// Async cover thumbnail. Books without a cover image render their first
/// page (CoverThumb's fallback); while loading — or when even that fails —
/// the cell shows the book's generated-cover tint with its title, matching
/// the macOS library.
private struct CoverView: View {
    let item: LibraryItem
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                let (tint, lightText) = BookTint.cover(forPath: item.fileURL.path)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(platformColor: tint).opacity(0.85))
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(lightText ? .white : Color(hue: 0.1, saturation: 0.5, brightness: 0.25))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(8)
            }
        }
        .task(id: item.id) {
            image = await CoverThumb.thumbnail(for: item.coverURL ?? item.fileURL)
        }
    }
}
